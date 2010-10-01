%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(ns_bucket).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([config/1,
         config_string/1,
         credentials/1,
         get_bucket/1,
         maybe_get_bucket/2,
         get_buckets/0,
         get_buckets/1,
         min_live_copies/0,
         min_live_copies/1,
         node_locator/1,
         ram_quota/1,
         raw_ram_quota/1,
         num_replicas/1,
         bucket_type/1,
         auth_type/1,
         sasl_password/1,
         moxi_port/1,
         bucket_nodes/1,
         get_bucket_names/0,
         get_bucket_names/1,
         json_map/2,
         json_map_from_config/2,
         set_bucket_config/2,
         is_valid_bucket_name/1,
         create_bucket/3,
         update_bucket_props/2,
         update_bucket_props/3,
         delete_bucket/1,
         set_map/2,
         set_servers/2]).


%%%===================================================================
%%% API
%%%===================================================================

config(Bucket) ->
    {ok, CurrentConfig} = get_bucket(Bucket),
    config_from_info(CurrentConfig).

config_from_info(CurrentConfig) ->
    NumReplicas = proplists:get_value(num_replicas, CurrentConfig),
    NumVBuckets = proplists:get_value(num_vbuckets, CurrentConfig),
    Map = case proplists:get_value(map, CurrentConfig) of
              undefined -> lists:duplicate(NumVBuckets, lists:duplicate(NumReplicas+1, undefined));
              M -> M
          end,
    Servers = proplists:get_value(servers, CurrentConfig),
    {NumReplicas, NumVBuckets, Map, Servers}.


%% @doc Configuration parameters to start up the bucket on a node.
config_string(BucketName) ->
    Config = ns_config:get(),
    BucketConfigs = ns_config:search_prop(Config, buckets, configs),
    BucketConfig = proplists:get_value(BucketName, BucketConfigs),
    Engines = ns_config:search_node_prop(Config, memcached, engines),
    MemQuota = proplists:get_value(ram_quota, BucketConfig),
    NodesCount = case length(proplists:get_value(servers, BucketConfig)) of
                     0 -> 1;
                     X -> X
                 end,
    BucketType =  proplists:get_value(type, BucketConfig),
    EngineConfig = proplists:get_value(BucketType, Engines),
    Engine = proplists:get_value(engine, EngineConfig),
    {ConfigString, ExtraParams} =
        case BucketType of
            membase ->
                LocalQuota = MemQuota div NodesCount,
                DBDir = ns_config:search_node_prop(Config, memcached, dbdir),
                DBName = filename:join(DBDir, BucketName),
                %% MemQuota is our total limit for cluster
                %% LocalQuota is our limit for this node
                %% We stretch our quota on all nodes we have for this bucket
                ok = filelib:ensure_dir(DBName),
                CFG =
                    lists:flatten(
                      io_lib:format(
                        "vb0=false;waitforwarmup=false;ht_size=~B;"
                        "ht_locks=~B;failpartialwarmup=false;"
                        "max_size=~B;initfile=~s;dbname=~s",
                        [proplists:get_value(ht_size, BucketConfig),
                         proplists:get_value(ht_locks, BucketConfig),
                         LocalQuota,
                         proplists:get_value(initfile, EngineConfig),
                         DBName])),
                {CFG, {LocalQuota, DBName}};
            memcached ->
                {lists:flatten(
                   io_lib:format("vb0=true;cache_size=~B", [MemQuota])),
                 MemQuota}
        end,
    {Engine, ConfigString, BucketType, ExtraParams}.

%% @doc Return {Username, Password} for a bucket.
-spec credentials(nonempty_string()) ->
                         {nonempty_string(), string()}.
credentials(Bucket) ->
    {ok, BucketConfig} = get_bucket(Bucket),
    {Bucket, proplists:get_value(sasl_password, BucketConfig, "")}.


get_bucket(Bucket) ->
    BucketConfigs = get_buckets(),
    case lists:keysearch(Bucket, 1, BucketConfigs) of
        {value, {_, Config}} ->
            {ok, Config};
        false -> not_present
    end.

maybe_get_bucket(BucketName, undefined) ->
    get_bucket(BucketName);
maybe_get_bucket(_, BucketConfig) ->
    {ok, BucketConfig}.

get_bucket_names() ->
    BucketConfigs = get_buckets(),
    proplists:get_keys(BucketConfigs).

get_bucket_names(Type) ->
    [Name || {Name, Config} <- get_buckets(),
             proplists:get_value(type, Config) == Type].

get_buckets() ->
    get_buckets(ns_config:get()).

get_buckets(Config) ->
     ns_config:search_prop(Config, buckets, configs, []).

%% returns cluster-wide ram_quota. For memcached buckets it's
%% ram_quota field times number of servers
-spec ram_quota([{_,_}]) -> integer().
ram_quota(Bucket) ->
    case proplists:get_value(ram_quota, Bucket) of
        X when is_integer(X) ->
            case proplists:get_value(type, Bucket) of
                memcached ->
                    X * length(ns_cluster_membership:active_nodes());
                _ -> X
            end
    end.

%% returns cluster-wide ram_quota. For memcached buckets it's
%% ram_quota field times number of servers
-spec raw_ram_quota([{_,_}]) -> integer().
raw_ram_quota(Bucket) ->
    case proplists:get_value(ram_quota, Bucket) of
        X when is_integer(X) ->
            X
    end.

%% @doc Return the minimum number of live copies for all membase buckets.
-spec min_live_copies() -> non_neg_integer() | undefined.
min_live_copies() ->
    case [Config || {_BucketName, Config} <- get_buckets(),
                    proplists:get_value(type, Config) == membase] of
        [] ->
            undefined;
        BucketConfigs ->
            LiveNodes = [node()|nodes()],
            CopyCounts = [min_live_copies(LiveNodes, BucketConfig)
                          || BucketConfig <- BucketConfigs],
            lists:min(CopyCounts)
    end.

-spec min_live_copies(string()) -> non_neg_integer() | undefined.
min_live_copies(Bucket) ->
    case get_bucket(Bucket) of
        {ok, Config} ->
            min_live_copies([node()|nodes()], Config);
        _ ->
            undefined
    end.

%% @doc Separate out the guts of can_fail_over to make it testable.
-spec min_live_copies([node()], list()) -> non_neg_integer() | undefined.
min_live_copies(LiveNodes, Config) ->
    case proplists:get_value(map, Config) of
        undefined -> undefined;
        Map ->
            lists:foldl(
              fun (Chain, Min) ->
                      NumLiveCopies =
                          lists:foldl(
                            fun (Node, Acc) ->
                                    case lists:member(Node, LiveNodes) of
                                        true -> Acc + 1;
                                        false -> Acc
                                    end
                            end, 0, Chain),
                      erlang:min(Min, NumLiveCopies)
              end, length(hd(Map)), Map)
    end.

node_locator(BucketConfig) ->
    case proplists:get_value(type, BucketConfig) of
        membase ->
            vbucket;
        memcached ->
            ketama
    end.

-spec num_replicas([{_,_}]) -> integer().
num_replicas(Bucket) ->
    case proplists:get_value(num_replicas, Bucket) of
        X when is_integer(X) ->
            X
    end.

bucket_type(Bucket) ->
    proplists:get_value(type, Bucket).

auth_type(Bucket) ->
    proplists:get_value(auth_type, Bucket).

sasl_password(Bucket) ->
    proplists:get_value(sasl_password, Bucket, "").

moxi_port(Bucket) ->
    proplists:get_value(moxi_port, Bucket).

bucket_nodes(Bucket) ->
    proplists:get_value(servers, Bucket).

json_map(BucketId, LocalAddr) ->
    {ok, BucketConfig} = get_bucket(BucketId),
    json_map_from_config(LocalAddr, BucketConfig).

json_map_from_config(LocalAddr, BucketConfig) ->
    NumReplicas = num_replicas(BucketConfig),
    Config = ns_config:get(),
    {NumReplicas, _, EMap, BucketNodes} = config_from_info(BucketConfig),
    ENodes = lists:delete(undefined, lists:usort(lists:append([BucketNodes |
                                                               EMap]))),
    Servers = lists:map(
                fun (ENode) ->
                        Port = ns_config:search_node_prop(ENode, Config,
                                                          memcached, port),
                        Host = case misc:node_name_host(ENode) of
                                   {_Name, "127.0.0.1"} -> LocalAddr;
                                   {_Name, H} -> H
                               end,
                        list_to_binary(Host ++ ":" ++ integer_to_list(Port))
                end, ENodes),
    Map = lists:map(fun (Chain) ->
                            lists:map(fun (undefined) -> -1;
                                          (N) -> misc:position(N, ENodes) - 1
                                      end, Chain)
                    end, EMap),
    {struct, [{hashAlgorithm, <<"CRC">>},
              {numReplicas, NumReplicas},
              {serverList, Servers},
              {vBucketMap, Map}]}.

set_bucket_config(Bucket, NewConfig) ->
    update_bucket_config(Bucket, fun (_) -> NewConfig end).

%% Here's code snippet from bucket-engine.  We also disallow '.' &&
%% '..' which cause problems with browsers even when properly
%% escaped. See bug 953
%%
%% static bool has_valid_bucket_name(const char *n) {
%%     bool rv = strlen(n) > 0;
%%     for (; *n; n++) {
%%         rv &= isalpha(*n) || isdigit(*n) || *n == '.' || *n == '%' || *n == '_' || *n == '-';
%%     }
%%     return rv;
%% }
is_valid_bucket_name([]) -> false;
is_valid_bucket_name(".") -> false;
is_valid_bucket_name("..") -> false;
is_valid_bucket_name([Char | Rest]) ->
    case ($A =< Char andalso Char =< $Z)
        orelse ($a =< Char andalso Char =< $z)
        orelse ($0 =< Char andalso Char =< $9)
        orelse Char =:= $. orelse Char =:= $%
        orelse Char =:= $_ orelse Char =:= $- of
        true ->
            case Rest of
                [] -> true;
                _ -> is_valid_bucket_name(Rest)
            end;
        _ -> false
    end.

new_bucket_default_params(membase) ->
    [{type, membase},
     {num_vbuckets,
      case (catch list_to_integer(os:getenv("VBUCKETS_NUM"))) of
          EnvBuckets when is_integer(EnvBuckets) -> EnvBuckets;
          _ -> 1024
      end},
     {num_replicas, 1},
     {ram_quota, 0},
     {ht_size, 3079},
     {ht_locks, 5},
     {servers, []},
     {map, undefined}];
new_bucket_default_params(memcached) ->
    [{type, memcached},
     {num_vbuckets, 0},
     {num_replicas, 0},
     {servers, ns_cluster_membership:active_nodes()},
     {map, []},
     {ram_quota, 0}].

cleanup_bucket_props(Props) ->
    case proplists:get_value(auth_type, Props) of
        sasl -> lists:keydelete(moxi_port, 1, Props);
        none -> lists:keydelete(sasl_password, 1, Props)
    end.

create_bucket(BucketType, BucketName, NewConfig) ->
    case is_valid_bucket_name(BucketName) of
        false ->
            {error, {invalid_name, BucketName}};
        _ ->
            MergedConfig0 =
                misc:update_proplist(new_bucket_default_params(BucketType),
                                     NewConfig),
            MergedConfig = cleanup_bucket_props(MergedConfig0),
            ns_config:update_sub_key(
              buckets, configs,
              fun (List) ->
                      case lists:keyfind(BucketName, 1, List) of
                          false -> ok;
                          Tuple ->
                              exit({already_exists, Tuple})
                      end,
                      [{BucketName, MergedConfig} | List]
              end)
            %% The janitor will handle creating the map.
    end.

delete_bucket(BucketName) ->
    ns_config:update_sub_key(buckets, configs,
                             fun (List) ->
                                     case lists:keyfind(BucketName, 1, List) of
                                         false -> exit({not_found, BucketName});
                                         Tuple ->
                                             lists:delete(Tuple, List)
                                     end
                             end).

%% Updates properties of bucket of given name and type.  Check of type
%% protects us from type change races in certain cases.
%%
%% If bucket with given name exists, but with different type, we
%% should return {exit, {not_found, _}, _}
update_bucket_props(Type, BucketName, Props) ->
    case lists:member(BucketName, get_bucket_names(Type)) of
        true ->
            update_bucket_props(BucketName, Props);
        false ->
            {exit, {not_found, BucketName}, []}
    end.

update_bucket_props(BucketName, Props) ->
    ns_config:update_sub_key(
      buckets, configs,
      fun (List) ->
              RV = misc:key_update(
                     BucketName, List,
                     fun (OldProps) ->
                             NewProps = lists:foldl(
                                          fun ({K, _V} = Tuple, Acc) ->
                                                  [Tuple | lists:keydelete(K, 1, Acc)]
                                          end, OldProps, Props),
                             cleanup_bucket_props(NewProps)
                     end),
              case RV of
                  false -> exit({not_found, BucketName});
                  _ -> ok
              end,
              RV
      end).

set_map(Bucket, Map) ->
    %% Make sure all lengths are the same
    ChainLengths = [length(Chain) || Chain <- Map],
    true = lists:max(ChainLengths) == lists:min(ChainLengths),
    %% Make sure there are no repeated nodes
    true = lists:all(
             fun (Chain) ->
                     Chain1 = [N || N <- Chain, N /= undefined],
                     length(lists:usort(Chain1)) == length(Chain1)
             end, Map),
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(map, 1, OldConfig, {map, Map})
      end).

set_servers(Bucket, Servers) ->
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(servers, 1, OldConfig, {servers, Servers})
      end).

% Update the bucket config atomically.
update_bucket_config(Bucket, Fun) ->
    ok = ns_config:update_key(
           buckets,
           fun (List) ->
                   Buckets = proplists:get_value(configs, List, []),
                   OldConfig = proplists:get_value(Bucket, Buckets),
                   NewConfig = Fun(OldConfig),
                   NewBuckets = lists:keyreplace(Bucket, 1, Buckets, {Bucket, NewConfig}),
                   lists:keyreplace(configs, 1, List, {configs, NewBuckets})
           end).


%%
%% Internal functions
%%

%%
%% Tests
%%

min_live_copies_test() ->
    ?assertEqual(min_live_copies([node1], []), undefined),
    ?assertEqual(min_live_copies([node1], [{map, undefined}]), undefined),
    Map1 = [[node1, node2], [node2, node1]],
    ?assertEqual(2, min_live_copies([node1, node2], [{map, Map1}])),
    ?assertEqual(1, min_live_copies([node1], [{map, Map1}])),
    ?assertEqual(0, min_live_copies([node3], [{map, Map1}])),
    Map2 = [[undefined, node2], [node2, node1]],
    ?assertEqual(1, min_live_copies([node1, node2], [{map, Map2}])),
    ?assertEqual(0, min_live_copies([node1, node3], [{map, Map2}])).
