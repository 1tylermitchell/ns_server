% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couchbase_compaction_daemon).
-behaviour(gen_server).

% public API
-export([start_link/0]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("couch_db.hrl").

% If N vbucket databases of a bucket need to be compacted, we trigger compaction
% for all the vbucket databases of that bucket.
-define(NUM_SAMPLE_VBUCKETS, 4).

-define(CONFIG_ETS, couch_compaction_daemon_config).
% The period to pause for after checking (and eventually compact) all
% databases and view groups.
-define(DISK_CHECK_PERIOD, 1).          % minutes
-define(KV_RE,
    [$^, "\\s*", "([^=]+?)", "\\s*", $=, "\\s*", "([^=]+?)", "\\s*", $$]).
-define(PERIOD_RE,
    [$^, "([^-]+?)", "\\s*", $-, "\\s*", "([^-]+?)", $$]).

-record(state, {
    loop_pid
}).

-record(config, {
    db_frag = nil,
    view_frag = nil,
    period = nil,
    cancel = false,
    parallel_view_compact = false
}).

-record(period, {
    from,
    to
}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init(_) ->
    process_flag(trap_exit, true),
    ?CONFIG_ETS = ets:new(?CONFIG_ETS, [named_table, set, protected]),
    Server = self(),
    ok = couch_config:register(
        fun("compactions", Db, NewValue) ->
            ok = gen_server:cast(Server, {config_update, Db, NewValue})
        end),
    load_config(),
    case start_os_mon() of
    ok ->
        Loop = spawn_link(fun() -> compact_loop(Server) end),
        {ok, #state{loop_pid = Loop}};
    {error, Error} ->
        {stop, Error}
    end.


start_os_mon() ->
    case application:start(os_mon) of
    ok ->
        ok = disksup:set_check_interval(?DISK_CHECK_PERIOD);
    {error, {already_started, os_mon}} ->
        ok;
    {error, _} = Error ->
        Error
    end.


handle_cast({config_update, DbName, deleted}, State) ->
    true = ets:delete(?CONFIG_ETS, ?l2b(DbName)),
    {noreply, State};

handle_cast({config_update, DbName, Config}, #state{loop_pid = Loop} = State) ->
    {ok, NewConfig} = parse_config(Config),
    WasEmpty = (ets:info(?CONFIG_ETS, size) =:= 0),
    true = ets:insert(?CONFIG_ETS, {?l2b(DbName), NewConfig}),
    case WasEmpty of
    true ->
        Loop ! {self(), have_config};
    false ->
        ok
    end,
    {noreply, State}.


handle_call(Msg, _From, State) ->
    {stop, {unexpected_call, Msg}, State}.


handle_info({'EXIT', Pid, Reason}, #state{loop_pid = Pid} = State) ->
    {stop, {compaction_loop_died, Reason}, State}.


terminate(_Reason, _State) ->
    true = ets:delete(?CONFIG_ETS).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


compact_loop(Parent) ->
    Me = node(),
    Buckets = lists:map(
        fun({Name, Config}) ->
            {_, VbNames} = lists:foldl(
                fun(Nodes, {Index, Acc}) ->
                    case lists:member(Me, Nodes) of
                    true ->
                        VbName = iolist_to_binary(
                            [Name, $/, integer_to_list(Index)]),
                        {Index + 1, [VbName | Acc]};
                    false ->
                        {Index + 1, Acc}
                    end
                end,
                {0, []}, couch_util:get_value(map, Config)),
            {VbNames, bucket_compact_config(?l2b(Name))}
        end,
        ns_bucket:get_buckets()),
    lists:foreach(
        fun({_VbNames, nil}) ->
            ok;
        ({VbNames, {ok, Config}}) ->
            maybe_compact_bucket(VbNames, Config)
        end,
        Buckets),
    case ets:info(?CONFIG_ETS, size) =:= 0 of
    true ->
        receive {Parent, have_config} -> ok end;
    false ->
        PausePeriod = list_to_integer(
            couch_config:get("compaction_daemon", "check_interval", "1")),
        ok = timer:sleep(PausePeriod * 1000)
    end,
    compact_loop(Parent).


maybe_compact_bucket(VbNames, Config) ->
    case bucket_needs_compaction(VbNames, Config) of
    false ->
        ok;
    true ->
        lists:foreach(fun(N) -> compact_vbucket(N, Config) end, VbNames)
    end.


bucket_needs_compaction(VbNames, Config) ->
    NumVbs = length(VbNames),
    SampleVbs = lists:map(
        fun(_) ->
             {I, _} = random:uniform_s(NumVbs, now()),
             lists:nth(I, VbNames)
        end,
        lists:seq(1, erlang:min(?NUM_SAMPLE_VBUCKETS, NumVbs))),
    % Don't care about duplicates.
    vbuckets_need_compaction(lists:usort(SampleVbs), Config, true).


vbuckets_need_compaction([], _Config, Acc) ->
    Acc;
vbuckets_need_compaction(_DbNames, _Config, false) ->
    false;
vbuckets_need_compaction([DbName | Rest], Config, Acc) ->
    case (catch couch_db:open_int(DbName, [])) of
    {ok, Db} ->
        Acc2 = Acc andalso can_db_compact(Config, Db),
        couch_db:close(Db),
        vbuckets_need_compaction(Rest, Config, Acc2);
    Error ->
        ?LOG_ERROR("Couldn't open vbucket database `~s`: ~p", [DbName, Error]),
        false
    end.


compact_vbucket(DbName, Config) ->
    case (catch couch_db:open_int(DbName, [])) of
    {ok, Db} ->
        {ok, DbCompactPid} = couch_db:start_compact(Db),
        TimeLeft = compact_time_left(Config),
        case Config#config.parallel_view_compact of
        true ->
            ViewsCompactPid = spawn(fun() ->
                {ok, Db2} = couch_db:open_int(DbName, []),
                maybe_compact_views(Db2, Config),
                couch_db:close(Db2)
            end),
            ViewsMonRef = erlang:monitor(process, ViewsCompactPid);
        false ->
            ViewsMonRef = nil
        end,
        DbMonRef = erlang:monitor(process, DbCompactPid),
        receive
        {'DOWN', DbMonRef, process, _, normal} ->
            case Config#config.parallel_view_compact of
            true ->
                ok;
            false ->
                maybe_compact_views(Db, Config)
            end;
        {'DOWN', DbMonRef, process, _, Reason} ->
            ?LOG_ERROR("Compaction daemon - an error ocurred while"
                " compacting the database `~s`: ~p", [DbName, Reason])
        after TimeLeft ->
            ?LOG_INFO("Compaction daemon - canceling compaction for database"
                " `~s` because it's exceeding the allowed period.", [DbName]),
            ok = couch_db:cancel_compact(Db)
        end,
        couch_db:close(Db),
        case ViewsMonRef of
        nil ->
            ok;
        _ ->
            receive
            {'DOWN', ViewsMonRef, process, _, _Reason} ->
                ok
            end
        end;
    Error ->
        ?LOG_ERROR("Couldn't open vbucket database `~s`: ~p", [DbName, Error])
    end.


maybe_compact_views(Db, Config) ->
    {ok, _, ok} = couch_db:enum_docs(
        Db,
        fun(#full_doc_info{id = <<"_design/", Id/binary>>}, _, Acc) ->
            maybe_compact_view(Db, Id, Config),
            {ok, Acc};
        (_, _, Acc) ->
            {stop, Acc}
        end, ok, [{start_key, <<"_design/">>}, {end_key_gt, <<"_design0">>}]).


maybe_compact_view(#db{name = DbName} = Db, GroupId, Config) ->
    DDocId = <<"_design/", GroupId/binary>>,
    case (catch couch_view:get_group_info(Db, DDocId)) of
    {ok, GroupInfo} ->
        case can_view_compact(Config, Db, GroupId, GroupInfo) of
        true ->
            {ok, CompactPid} = couch_view_compactor:start_compact(DbName, GroupId),
            TimeLeft = compact_time_left(Config),
            MonRef = erlang:monitor(process, CompactPid),
            receive
            {'DOWN', MonRef, process, CompactPid, normal} ->
                ok;
            {'DOWN', MonRef, process, CompactPid, Reason} ->
                ?LOG_ERROR("Compaction daemon - an error ocurred while compacting"
                    " the view group `~s` from database `~s`: ~p",
                    [GroupId, DbName, Reason])
            after TimeLeft ->
                ?LOG_INFO("Compaction daemon - canceling the compaction for the "
                    "view group `~s` of the database `~s` because it's exceeding"
                    " the allowed period.", [GroupId, DbName]),
                ok = couch_view_compactor:cancel_compact(DbName, GroupId)
            end;
        false ->
            ok
        end;
    _ ->
        ok
    end.


compact_time_left(#config{cancel = false}) ->
    infinity;
compact_time_left(#config{period = nil}) ->
    infinity;
compact_time_left(#config{period = #period{to = {ToH, ToM} = To}}) ->
    {H, M, _} = time(),
    case To > {H, M} of
    true ->
        ((ToH - H) * 60 * 60 * 1000) + (abs(ToM - M) * 60 * 1000);
    false ->
        ((24 - H + ToH) * 60 * 60 * 1000) + (abs(ToM - M) * 60 * 1000)
    end.


bucket_compact_config(BucketName) ->
    case ets:lookup(?CONFIG_ETS, BucketName) of
    [] ->
        case ets:lookup(?CONFIG_ETS, <<"_default">>) of
        [] ->
            nil;
        [{<<"_default">>, Config}] ->
            {ok, Config}
        end;
    [{BucketName, Config}] ->
        {ok, Config}
    end.


can_db_compact(#config{db_frag = Threshold} = Config, Db) ->
    case check_period(Config) of
    false ->
        false;
    true ->
        {ok, DbInfo} = couch_db:get_db_info(Db),
        {Frag, SpaceRequired} = frag(DbInfo),
        ?LOG_DEBUG("Fragmentation for database `~s` is ~p%, estimated space for"
           " compaction is ~p bytes.", [Db#db.name, Frag, SpaceRequired]),
        case check_frag(Threshold, Frag) of
        false ->
            false;
        true ->
            Free = free_space(couch_config:get("couchdb", "database_dir")),
            case Free >= SpaceRequired of
            true ->
                true;
            false ->
                ?LOG_INFO("Compaction daemon - skipping database `~s` "
                    "compaction: the estimated necessary disk space is about ~p"
                    " bytes but the currently available disk space is ~p bytes.",
                   [Db#db.name, SpaceRequired, Free]),
                false
            end
        end
    end.

can_view_compact(Config, Db, GroupId, GroupInfo) ->
    case check_period(Config) of
    false ->
        false;
    true ->
        case couch_util:get_value(updater_running, GroupInfo) of
        true ->
            false;
        false ->
            {Frag, SpaceRequired} = frag(GroupInfo),
            ?LOG_DEBUG("Fragmentation for view group `~s` (database `~s`) is "
                "~p%, estimated space for compaction is ~p bytes.",
                [GroupId, Db#db.name, Frag, SpaceRequired]),
            case check_frag(Config#config.view_frag, Frag) of
            false ->
                false;
            true ->
                Free = free_space(couch_config:get("couchdb", "view_index_dir")),
                case Free >= SpaceRequired of
                true ->
                    true;
                false ->
                    ?LOG_INFO("Compaction daemon - skipping view group `~s` "
                        "compaction (database `~s`): the estimated necessary "
                        "disk space is about ~p bytes but the currently available"
                        " disk space is ~p bytes.",
                        [GroupId, Db#db.name, SpaceRequired, Free]),
                    false
                end
            end
        end
    end.


check_period(#config{period = nil}) ->
    true;
check_period(#config{period = #period{from = From, to = To}}) ->
    {HH, MM, _} = erlang:time(),
    case From < To of
    true ->
        ({HH, MM} >= From) andalso ({HH, MM} < To);
    false ->
        ({HH, MM} >= From) orelse ({HH, MM} < To)
    end.


check_frag(nil, _) ->
    true;
check_frag(Threshold, Frag) ->
    Frag >= Threshold.


frag(Props) ->
    FileSize = couch_util:get_value(disk_size, Props),
    MinFileSize = list_to_integer(
        couch_config:get("compaction_daemon", "min_file_size", "131072")),
    case FileSize < MinFileSize of
    true ->
        {0, FileSize};
    false ->
        case couch_util:get_value(data_size, Props) of
        null ->
            {100, FileSize};
        0 ->
            {0, FileSize};
        DataSize ->
            Frag = round(((FileSize - DataSize) / FileSize * 100)),
            {Frag, space_required(DataSize)}
        end
    end.

% Rough, and pessimistic, estimation of necessary disk space to compact a
% database or view index.
space_required(DataSize) ->
    round(DataSize * 2.0).


load_config() ->
    lists:foreach(
        fun({DbName, ConfigString}) ->
            case (catch parse_config(ConfigString)) of
            {ok, Config} ->
                true = ets:insert(?CONFIG_ETS, {?l2b(DbName), Config});
            _ ->
                ?LOG_ERROR("Invalid compaction configuration for database "
                    "`~s`: `~s`", [DbName, ConfigString])
            end
        end,
        couch_config:get("compactions")).


parse_config(ConfigString) ->
    KVs = lists:map(
        fun(Pair) ->
            {match, [K, V]} = re:run(Pair, ?KV_RE, [{capture, [1, 2], list}]),
            {K, V}
        end,
        string:tokens(string:to_lower(ConfigString), ",")),
    Config = lists:foldl(
        fun({"db_fragmentation", V0}, Config) ->
            [V] = string:tokens(V0, "%"),
            Config#config{db_frag = list_to_integer(V)};
        ({"view_fragmentation", V0}, Config) ->
            [V] = string:tokens(V0, "%"),
            Config#config{view_frag = list_to_integer(V)};
        ({"period", V}, Config) ->
            {match, [From, To]} = re:run(
                V, ?PERIOD_RE, [{capture, [1, 2], list}]),
            [FromHH, FromMM] = string:tokens(From, ":"),
            [ToHH, ToMM] = string:tokens(To, ":"),
            Config#config{
                period = #period{
                    from = {list_to_integer(FromHH), list_to_integer(FromMM)},
                    to = {list_to_integer(ToHH), list_to_integer(ToMM)}
                }
            };
        ({"strict_window", V}, Config) when V =:= "yes"; V =:= "true" ->
            Config#config{cancel = true};
        ({"strict_window", V}, Config) when V =:= "no"; V =:= "false" ->
            Config#config{cancel = false};
        ({"parallel_view_compaction", V}, Config) when V =:= "yes"; V =:= "true" ->
            Config#config{parallel_view_compact = true};
        ({"parallel_view_compaction", V}, Config) when V =:= "no"; V =:= "false" ->
            Config#config{parallel_view_compact = false}
        end, #config{}, KVs),
    {ok, Config}.


free_space(Path) ->
    DiskData = lists:sort(
        fun({PathA, _, _}, {PathB, _, _}) ->
            length(filename:split(PathA)) > length(filename:split(PathB))
        end,
        disksup:get_disk_data()),
    free_space_rec(abs_path(Path), DiskData).

free_space_rec(_Path, []) ->
    undefined;
free_space_rec(Path, [{MountPoint0, Total, Usage} | Rest]) ->
    MountPoint = abs_path(MountPoint0),
    case MountPoint =:= string:substr(Path, 1, length(MountPoint)) of
    false ->
        free_space_rec(Path, Rest);
    true ->
        trunc(Total - (Total * (Usage / 100))) * 1024
    end.

abs_path(Path0) ->
    Path = filename:absname(Path0),
    case lists:last(Path) of
    $/ ->
        Path;
    _ ->
        Path ++ "/"
    end.
