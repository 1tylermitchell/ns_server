%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2018 Couchbase, Inc.
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
-module(leader_activities).

-behaviour(gen_server2).

-include("cut.hrl").
-include("ns_common.hrl").

%% API
-export([start_link/0]).

-export([start_activity/3, start_activity/4]).
-export([start_activity/5, start_activity/6]).

-export([run_activity/3, run_activity/4, run_activity/5, run_activity/6]).

-export([register_process/2, register_process/3]).
-export([register_process/4, register_process/5]).

-export([switch_quorum/1, switch_quorum/2]).

%% used only by leader_* modules only
-export([register_acquirer/1, register_agent/1]).
-export([lease_acquired/2, lease_lost/2]).
-export([local_lease_granted/2, local_lease_expired/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(QUORUM_TIMEOUT,        ?get_timeout(quorum_timeout, 15000)).
-define(UNSAFE_QUORUM_TIMEOUT, ?get_timeout(unsafe_quorum_timeout, 2000)).

-type lease_holder() :: {node(), binary()}.

-type user_quorum() :: quorum(sets:set(node()) | [node()]).

-type quorum() :: quorum(sets:set(node())).
-type quorum(Nodes) :: all
                     | follower
                     | majority
                     | {all, Nodes}
                     | {majority, Nodes}
                     | [quorum(Nodes)].

-type activity_option() :: {quorum_timeout, non_neg_integer()}
                         | {timeout, non_neg_integer()}
                         | quiet
                         | unsafe.
-type activity_options() :: [activity_option()].

-record(activity, { pid          :: pid(),
                    mref         :: reference(),
                    domain       :: term(),
                    domain_token :: binary() | any(),
                    name         :: [term()],
                    quorum       :: quorum(),
                    options      :: activity_options() }).

-record(activity_token, { lease        :: leader | {node(), binary()},
                          domain_token :: binary(),
                          domain       :: term(),
                          name         :: [term()],
                          options      :: activity_options() }).

-record(state, { agent    :: undefined | {pid(), reference()},
                 acquirer :: undefined | {pid(), reference()},

                 quorum_nodes       :: sets:set(node()),
                 leases             :: sets:set(node()),
                 local_lease_holder :: undefined | lease_holder(),

                 activities :: [#activity{}]
               }).

start_link() ->
    leader_utils:ignore_if_new_orchestraction_disabled(
      fun () ->
          gen_server2:start_link({local, ?SERVER}, ?MODULE, [], [])
      end).

register_acquirer(Pid) ->
    call_register_internal_process(acquirer, Pid).

register_agent(Pid) ->
    call_register_internal_process(agent, Pid).

lease_acquired(Pid, Node) ->
    call_if_internal_process(acquirer, Pid, {lease_acquired, Node}).

lease_lost(Pid, Node) ->
    call_if_internal_process(acquirer, Pid, {lease_lost, Node}).

local_lease_granted(Pid, LocalLease) ->
    call_if_internal_process(agent, Pid, {local_lease_granted, LocalLease}).

local_lease_expired(Pid, LocalLease) ->
    call_if_internal_process(agent, Pid, {local_lease_expired, LocalLease}).

run_activity(Name, Quorum, Body) ->
    run_activity(Name, Quorum, Body, []).

run_activity(Name, Quorum, Body, Opts) ->
    run_activity(default, Name, Quorum, Body, Opts).

run_activity(Domain, Name, Quorum, Body, Opts) ->
    run_activity(node(), Domain, Name, Quorum, Body, Opts).

run_activity(Node, Domain, Name, Quorum, Body, Opts) ->
    case async:get_identity() of
        {ok, _Async} ->
            case start_activity(Node, Domain, Name, Quorum, Body, Opts) of
                {ok, Activity} ->
                    try
                        async:wait(Activity)
                    catch
                        exit:{shutdown, local_lease_expired = Reason} ->
                            report_error(Domain, Name, Reason);
                        exit:{shutdown, {quorum_lost, _} = Reason} ->
                            report_error(Domain, Name, Reason);
                        exit:{shutdown, {leader_process_died, _} = Reason} ->
                            report_error(Domain, Name, Reason)
                    end;
                {error, Error} ->
                    report_error(Domain, Name, Error)
            end;
        not_async ->
            MaybeToken = get_activity_token(),
            misc:executing_on_new_process(
              fun () ->
                      {ok, _} = async:get_identity(),

                      case MaybeToken of
                          {ok, Token} ->
                              set_activity_token(Token);
                          not_activity ->
                              ok
                      end,

                      run_activity(Domain, Name, Quorum, Body, Opts)
              end)
    end.

start_activity(Name, Quorum, Body) ->
    start_activity(Name, Quorum, Body, []).

start_activity(Name, Quorum, Body, Opts) ->
    start_activity(default, Name, Quorum, Body, Opts).

start_activity(Domain, Name, Quorum, Body, Opts) ->
    start_activity(node(), Domain, Name, Quorum, Body, Opts).

start_activity(Node, Domain, Name, Quorum, Body, Opts) ->
    pick_implementation(fun start_activity_regular/6,
                        fun start_activity_bypass/6,
                        [Node, Domain, Name, Quorum, Body, Opts]).

start_activity_regular(Node, Domain, Name, Quorum, Body, Opts) ->
    ActivityToken = case get_activity_token() of
                        {ok, Token} ->
                            true = (Token#activity_token.domain =:= Domain),
                            Token;
                        not_activity ->
                            make_fresh_activity_token(Domain)
                    end,

    start_activity_with_token(Node, ActivityToken, Name, Quorum, Body, Opts).

start_activity_with_token(Node, ActivityToken, Name, Quorum, Body, Opts) ->
    {ok, Async} = async:get_identity(),

    FinalOpts = merge_options(Opts, ActivityToken#activity_token.options),
    check_activity_body(Node, Body),
    call_wait_for_quorum(Node, ActivityToken, Quorum, FinalOpts,
                         start_activity, [Async, Name, Body]).

start_activity_bypass(Node, _Domain, _Name, _Quorum, Body, _Opts) ->
    AsyncBody = case Node =:= node() of
                    true ->
                        ?cut(run_body(Body));
                    false ->
                        {M, F, A} = Body,
                        fun () ->
                                case rpc:call(Node, M, F, A) of
                                    {badrpc, _} = Error ->
                                        throw(Error);
                                    Other ->
                                        Other
                                end
                        end
                end,

    Async = async:start(AsyncBody),
    {ok, Async}.

register_process(Name, Quorum) ->
    register_process(Name, Quorum, []).

register_process(Name, Quorum, Opts) ->
    register_process(default, undefined, Name, Quorum, Opts).

register_process(DomainToken, Name, Quorum, Opts) ->
    register_process(default, DomainToken, Name, Quorum, Opts).

register_process(Domain, DomainToken, Name, Quorum, Opts) ->
    pick_implementation(fun register_process_regular/5,
                        fun register_process_bypass/5,
                        [Domain, DomainToken, Name, Quorum, Opts]).

register_process_regular(Domain, DomainToken, Name, Quorum, Opts) ->
    {ok, ActivityToken} =
        call_wait_for_quorum(node(),
                             make_fresh_activity_token(Domain, DomainToken),
                             Quorum, Opts, register_process, [Name, self()]),
    set_activity_token(ActivityToken).

register_process_bypass(_Domain, _DomainToken, _Name, _Quorum, _Opts) ->
    ok.

switch_quorum(NewQuorum) ->
    switch_quorum(NewQuorum, []).

switch_quorum(NewQuorum, Opts) ->
    pick_implementation(fun switch_quorum_regular/2,
                        fun switch_quorum_bypass/2,
                        [NewQuorum, Opts]).

switch_quorum_regular(NewQuorum, Opts) ->
    Activity            = get_activity_pid(),
    {ok, ActivityToken} = get_activity_token(),

    EffectiveOpts = Opts ++ ActivityToken#activity_token.options,
    call_wait_for_quorum(node(),
                         ActivityToken,
                         NewQuorum, EffectiveOpts, switch_quorum, [Activity]).

switch_quorum_bypass(_NewQuorum, _Opts) ->
    ok.

%% gen_server callbacks
init([]) ->
    process_flag(priority, high),
    process_flag(trap_exit, true),

    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events,
                             case _ of
                                 {nodes_wanted, _} ->
                                     Self ! update_quorum_nodes;
                                 {node, _, membership} ->
                                     Self ! update_quorum_nodes;
                                 _ ->
                                     ok
                             end),

    {ok, #state{quorum_nodes       = get_quorum_nodes(),
                leases             = sets:new(),
                local_lease_holder = undefined,

                activities = []}}.

handle_call({if_internal_process, Type, Pid, SubCall}, From, State) ->
    {noreply, handle_if_internal_process(Type, Pid, SubCall, From, State)};
handle_call({wait_for_quorum,
             Lease, Quorum, Unsafe, SubCall, Timeout}, From, State) ->
    {noreply, handle_wait_for_quorum(Lease, Quorum, Unsafe,
                                     SubCall, Timeout, From, State)};
handle_call(Request, From, State) ->
    ?log_error("Received unexpected call ~p from ~p when state is~n~p",
               [Request, From, State]),
    {reply, nack, State}.

handle_cast(Msg, State) ->
    ?log_error("Received unexpected cast ~p when state is~n~p", [Msg, State]),
    {noreply, State}.

handle_info(update_quorum_nodes, State) ->
    {noreply, handle_update_quorum_nodes(State)};
handle_info({'DOWN', MRef, process, Pid, Reason}, State) ->
    {noreply, handle_down(MRef, Pid, Reason, State)};
handle_info({'EXIT', _Pid, _Reason} = Exit, State) ->
    ?log_error("Received unexpected exit message ~p. Exiting"),
    {stop, {unexpected_exit, Exit}, State};
handle_info(Info, State) ->
    ?log_error("Received unexpected message ~p when state is~n~p",
               [Info, State]),
    {noreply, State}.

terminate(Reason, State) ->
    terminate_all_activities(State, Reason).

%% internal functions
call_register_internal_process(Type, Pid) ->
    call_if_internal_process(Type, undefined,
                             {register_internal_process, Type, Pid}).

call_if_internal_process(Type, Pid, SubCall) ->
    call({if_internal_process, Type, Pid, SubCall}, infinity).

call_wait_for_quorum(Node, Token, UserQuorum, Opts, Call, Args) ->
    Unsafe        = proplists:get_bool(unsafe, Opts),
    QuorumTimeout = quorum_timeout(Opts, Unsafe),
    OuterTimeout  = proplists:get_value(timeout, Opts, QuorumTimeout + 5000),

    Lease       = Token#activity_token.lease,
    Domain      = Token#activity_token.domain,
    DomainToken = Token#activity_token.domain_token,
    TokenName   = Token#activity_token.name,

    Quorum  = convert_quorum(UserQuorum),
    SubCall = list_to_tuple([Call,
                             Domain,
                             DomainToken, TokenName, Quorum, Opts | Args]),

    call(Node, {wait_for_quorum,
                Lease, Quorum, Unsafe, SubCall, QuorumTimeout}, OuterTimeout).

quorum_timeout(Opts, Unsafe) ->
    Default =
        case Unsafe of
            true ->
                ?UNSAFE_QUORUM_TIMEOUT;
            false ->
                ?QUORUM_TIMEOUT
        end,

    proplists:get_value(quorum_timeout, Opts, Default).

call(Call, Timeout) ->
    call(node(), Call, Timeout).

call(Node, Call, Timeout) ->
    gen_server2:call({?SERVER, Node}, Call, Timeout).

check_no_domain_conflicts(ActivityToken, From, State, OnSuccess) ->
    #activity_token{domain       = Domain,
                    domain_token = DomainToken} = ActivityToken,

    case find_activity(Domain, #activity.domain, State) of
        {ok, FoundActivity} ->
            case FoundActivity#activity.domain_token =:= DomainToken of
                true ->
                    OnSuccess();
                false ->
                    ?log_error("Can't start activity ~p, "
                               "because of token conflict with~n~p",
                               [ActivityToken, FoundActivity]),
                    gen_server2:reply(From, {error,
                                             {domain_conflict,
                                              ActivityToken, FoundActivity}}),
                    State
            end;
        not_found ->
            OnSuccess()
    end.

handle_start_activity(Async,
                      Domain,
                      DomainToken, Name, Quorum, Opts, Body, From, State) ->
    ActivityToken = make_activity_token(Domain, DomainToken, Name, Opts, State),
    check_no_domain_conflicts(
      ActivityToken, From, State,
      fun () ->
              {Pid, MRef} = async:start(
                              fun () ->
                                      set_activity_token(ActivityToken),
                                      run_body(Body)
                              end,
                              [monitor, {adopters, [Async]}]),
              gen_server2:reply(From, {ok, Pid}),
              add_activity(ActivityToken, Quorum, Opts, Pid, MRef, State)
      end).

handle_register_process(Domain,
                        DomainToken, Name, Quorum, Opts, Pid, From, State) ->
    ActivityToken = make_activity_token(Domain, DomainToken, Name, Opts, State),
    check_no_domain_conflicts(
      ActivityToken, From, State,
      fun () ->
              MRef = erlang:monitor(process, Pid),
              gen_server2:reply(From, {ok, ActivityToken}),
              add_activity(ActivityToken, Quorum, Opts, Pid, MRef, State)
      end).

handle_if_internal_process(Type, Pid, SubCall, From, State) ->
    ExpectedPid = extract_internal_process_pid(Type, State),

    case Pid =:= ExpectedPid of
        true ->
            handle_if_internal_process_subcall(Type, SubCall, From, State);
        false ->
            Reply = {error, {wrong_pid, Type, Pid, ExpectedPid}},
            gen_server2:reply(From, Reply),
            State
    end.

handle_if_internal_process_subcall(Type,
                                   {register_internal_process, Type, Pid},
                                   From, State) ->
    handle_register_internal_process(Type, Pid, From, State);
handle_if_internal_process_subcall(acquirer,
                                   {lease_acquired, Node}, From, State) ->
    handle_lease_acquired(Node, From, State);
handle_if_internal_process_subcall(acquirer,
                                   {lease_lost, Node}, From, State) ->
    handle_lease_lost(Node, From, State);
handle_if_internal_process_subcall(agent,
                                   {local_lease_granted, LocalLease},
                                   From, State) ->
    handle_local_lease_granted(LocalLease, From, State);
handle_if_internal_process_subcall(agent,
                                   {local_lease_expired, LocalLease},
                                   From, State) ->
    handle_local_lease_expired(LocalLease, From, State);
handle_if_internal_process_subcall(Type, SubCall, From, State) ->
    ?log_error("Received unexpected internal process ~p "
               "subcall ~p from ~p, state =~n~p",
               [Type, SubCall, From, State]),
    gen_server2:reply(From, nack),
    State.

handle_register_internal_process(Type, Pid, From, State) ->
    undefined = extract_internal_process_pid(Type, State),

    gen_server2:reply(From, {ok, self()}),

    MRef = erlang:monitor(process, Pid),
    set_internal_process(Type, {Pid, MRef}, State).

handle_down(MRef, Pid, Reason, State) ->
    R = functools:alternative(
          State, [handle_internal_process_down(MRef, Pid, Reason, _),
                  handle_activity_down(MRef, Pid, Reason, _)]),

    case R of
        {ok, NewState} ->
            NewState;
        false ->
            ?log_error("Received unexpected DOWN message ~p",
                       [{MRef, Pid, Reason}]),
            exit({unexpected_down, MRef, Pid, Reason})
    end.

handle_internal_process_down(MRef, Pid, Reason, State) ->
    functools:alternative(
      State,
      [handle_internal_process_down(Type, MRef, Pid, Reason, _) ||
          {Type, _} <- internal_processes()]).

handle_internal_process_down(Type, MRef, Pid, Reason, State) ->
    case extract_internal_process(Type, State) =:= {Pid, MRef} of
        true ->
            ?log_debug("Process ~p terminated with reason ~p",
                       [{Type, Pid}, Reason]),
            {ok, cleanup_after_internal_process(Type, State)};
        false ->
            false
    end.

handle_activity_down(MRef, Pid, Reason, State) ->
    case take_activity(MRef, #activity.mref, State) of
        not_found ->
            false;
        {ok, Activity, NewState} ->
            true = (Activity#activity.pid =:= Pid),

            case is_verbose(Activity)
                orelse not misc:is_normal_termination(Reason) of
                true ->
                    ?log_debug("Activity "
                               "terminated with reason ~p. Activity:~n~p",
                               [Reason, Activity]);
                false ->
                    ok
            end,

            {ok, NewState}
    end.

handle_lease_acquired(Node, From, State) ->
    gen_server2:reply(From, ok),
    misc:update_field(#state.leases, State, sets:add_element(Node, _)).

handle_lease_lost(Node, From, State) ->
    NewState0 = misc:update_field(#state.leases, State,
                                  sets:del_element(Node, _)),
    NewState  = check_quorums(NewState0, {lease_lost, Node}),

    gen_server2:reply(From, ok),
    NewState.

handle_local_lease_granted(LocalLease, From, State) ->
    undefined = State#state.local_lease_holder,

    gen_server2:reply(From, ok),
    State#state{local_lease_holder = LocalLease}.

handle_local_lease_expired(LocalLease, From, State) ->
    true = (State#state.local_lease_holder =:= LocalLease),

    NewState = expire_local_lease(State),
    gen_server2:reply(From, ok),
    NewState.

expire_local_lease(State) ->
    NewState = State#state{local_lease_holder = undefined},
    terminate_all_activities(NewState, {shutdown, local_lease_expired}).

set_internal_process(Type, Value, State) ->
    setelement(internal_process_type_to_field(Type), State, Value).

internal_processes() ->
    [{agent, #state.agent},
     {acquirer, #state.acquirer}].

internal_process_type_to_field(Type) ->
    {Type, Field} = lists:keyfind(Type, 1, internal_processes()),
    Field.

extract_internal_process(Type, State) ->
    element(internal_process_type_to_field(Type), State).

extract_internal_process_pid(Type, State) ->
    case extract_internal_process(Type, State) of
        undefined ->
            undefined;
        {Pid, _MRef} ->
            Pid
    end.

cleanup_after_internal_process(Type, State) ->
    functools:chain(State,
                    [set_internal_process(Type, undefined, _),
                     cleanup_activities_after_internal_process(Type, _)]).

cleanup_activities_after_internal_process(agent, State) ->
    expire_local_lease(State);
cleanup_activities_after_internal_process(acquirer, State) ->
    NewState = State#state{leases = sets:new()},
    cleanup_after_leader_internal_process(acquirer, NewState).

cleanup_after_leader_internal_process(Type, State) ->
    Pred = ?cut(quorum_requires_leader(_#activity.quorum)),
    terminate_activities(Pred, State,
                         {shutdown, {leader_process_died, Type}}).

terminate_activities([], _Reason) ->
    ok;
terminate_activities(Activities, Reason) ->
    ?log_debug("Terminating activities (reason is ~p):~n~p",
               [Reason, Activities]),

    lists:foreach(?cut(erlang:demonitor(_#activity.mref, [flush])), Activities),
    misc:terminate_and_wait([A#activity.pid || A <- Activities], Reason).

terminate_activities(Pred, State, Reason) ->
    {Matching, Rest} = lists:partition(Pred, State#state.activities),
    terminate_activities(Matching, Reason),

    State#state{activities = Rest}.

terminate_all_activities(State, Reason) ->
    terminate_activities(functools:const(true), State, Reason).

add_activity(Token, Quorum, Opts, Pid, MRef, State) ->
    Activity = #activity{pid          = Pid,
                         mref         = MRef,
                         domain       = Token#activity_token.domain,
                         domain_token = Token#activity_token.domain_token,
                         name         = Token#activity_token.name,
                         quorum       = Quorum,
                         options      = Opts},

    case is_verbose(Activity) of
        true ->
            ?log_debug("Added activity:~n~p", [Activity]);
        false ->
            ok
    end,

    add_activity(Activity, State).

add_activity(Activity, State)
  when is_record(Activity, activity) ->
    misc:update_field(#state.activities, State, [Activity | _]).

find_activity(Key, N, #state{activities = Activities}) ->
    case lists:keyfind(Key, N, Activities) of
        false ->
            not_found;
        A when is_record(A, activity) ->
            {ok, A}
    end.

take_activity(Key, N, #state{activities = Activities} = State) ->
    case lists:keytake(Key, N, Activities) of
        false ->
            not_found;
        {value, A, Rest} ->
            {ok, A, State#state{activities = Rest}}
    end.

is_leader(#state{local_lease_holder = {Node, _},
                 acquirer           = Acquirer}) ->
    Acquirer =/= undefined andalso Node =:= node();
is_leader(_) ->
    false.

have_lease(leader, State) ->
    is_leader(State);
have_lease(ExpectedLease, #state{local_lease_holder = ActualLease}) ->
    ExpectedLease =:= ActualLease.

have_quorum(follower, State) ->
    true = (State#state.local_lease_holder =/= undefined),
    true;
have_quorum(Tag, State)
  when Tag =:= all;
       Tag =:= majority ->
    have_quorum({Tag, State#state.quorum_nodes}, State);
have_quorum({all, Nodes}, #state{leases = Leases}) ->
    sets:is_subset(Nodes, Leases);
have_quorum({majority, Nodes}, #state{leases = Leases}) ->
    Required = sets:size(Nodes) div 2,
    sets:size(sets:intersection(Nodes, Leases)) > Required;
have_quorum(Quorums, State)
  when is_list(Quorums) ->
    lists:all(have_quorum(_, State), Quorums).

quorum_requires_leader(follower) ->
    false;
quorum_requires_leader(Quorum)
  when is_list(Quorum) ->
    lists:any(fun quorum_requires_leader/1, Quorum);
quorum_requires_leader(_) ->
    true.

check_quorum_requires_leader(Quorum, State) ->
    case quorum_requires_leader(Quorum) of
        true ->
            is_leader(State);
        false ->
            true
    end.

check_quorum(Activity, State) ->
    Unsafe = proplists:get_bool(unsafe, get_options(Activity)),
    check_quorum(Unsafe, Activity#activity.quorum, State).

check_quorum(Unsafe, Quorum, State) ->
    Unsafe orelse have_quorum(Quorum, State).

check_quorums(State, Reason) ->
    terminate_activities(?cut(not check_quorum(_, State)),
                         State, {shutdown, {quorum_lost, Reason}}).

handle_wait_for_quorum(Lease,
                       Quorum, Unsafe, SubCall, Timeout, From, State) ->
    gen_server2:conditional(
      wait_for_quorum_pred(Lease, Quorum, _),
      ?cut(handle_wait_for_quorum_success(SubCall, From, _2)),
      Timeout,
      handle_wait_for_quorum_timeout(Unsafe, SubCall, Timeout,
                                     From, Lease, Quorum, _)),

    State.

wait_for_quorum_pred(Lease, Quorum, State) ->
    wait_for_quorum_pred(false, Lease, Quorum, State).

wait_for_quorum_pred(Unsafe, Lease, Quorum, State) ->
    have_lease(Lease, State)
        andalso check_quorum_requires_leader(Quorum, State)
        andalso check_quorum(Unsafe, Quorum, State).

handle_wait_for_quorum_success(SubCall, From, State) ->
    {noreply, handle_activity_subcall(SubCall, From, State)}.

handle_wait_for_quorum_timeout(false, _, _, From,
                               RequiredLease, RequiredQuorum, State) ->
    reply_no_quorum(From, RequiredLease, RequiredQuorum, State);
handle_wait_for_quorum_timeout(true, SubCall, Timeout, From,
                               RequiredLease, RequiredQuorum,
                               #state{leases = RemoteLeases} = State) ->
    case wait_for_quorum_pred(true, RequiredLease, RequiredQuorum, State) of
        true ->
            ?log_debug("Failed to acquire quorum for call ~p after ~bms. "
                       "Continuing since 'unsafe' option is set.~n"
                       "Required quorum: ~p~n"
                       "Leases: ~p",
                       [SubCall, Timeout, RequiredQuorum, RemoteLeases]),
            handle_wait_for_quorum_success(SubCall, From, State);
        false ->
            %% don't continue if we somehow don't even have the local
            %% lease/required leader processes registered
            reply_no_quorum(From, RequiredLease, RequiredQuorum, State)
    end.

reply_no_quorum(From, RequiredLease, RequiredQuorum,
                #state{local_lease_holder = LocalLease,
                       leases             = RemoteLeases} = State) ->
    gen_server2:reply(From, {error, {no_quorum,
                                     {RequiredLease,
                                      RequiredQuorum,
                                      LocalLease,
                                      sets:to_list(RemoteLeases)}}}),
    {noreply, State}.

handle_activity_subcall({start_activity,
                         Domain,
                         DomainToken,
                         ParentName, Quorum, Opts, Async, Name, Body},
                        From, State) ->
    FullName = ParentName ++ [Name],
    handle_start_activity(Async,
                          Domain,
                          DomainToken,
                          FullName, Quorum, Opts, Body, From, State);
handle_activity_subcall({register_process,
                         Domain,
                         DomainToken, ParentName, Quorum, Opts, Name, Pid},
                        From, State) ->
    FullName = ParentName ++ [Name],
    handle_register_process(Domain,
                            DomainToken,
                            FullName, Quorum, Opts, Pid, From, State);
handle_activity_subcall({switch_quorum,
                         Domain,
                         _DomainToken,
                         Name, Quorum, _Opts, Activity}, From, State) ->
    handle_switch_quorum(Domain, Name, Quorum, Activity, From, State);
handle_activity_subcall(Request, From, State) ->
    ?log_error("Received unexpected activity call ~p from ~p when state is~n~p",
               [Request, From, State]),
    gen_server2:reply(From, nack),
    State.

-spec convert_quorum(user_quorum()) -> quorum().
convert_quorum(Tag)
  when Tag =:= all;
       Tag =:= follower;
       Tag =:= majority ->
    Tag;
convert_quorum({Tag, Nodes} = UserQuorum)
  when Tag =:= all;
       Tag =:= majority ->

    case sets:is_set(Nodes) of
        true ->
            UserQuorum;
        false ->
            true = is_list(Nodes),
            {Tag, sets:from_list(Nodes)}
    end;
convert_quorum(Quorums)
  when is_list(Quorums) ->
    lists:map(fun convert_quorum/1, Quorums).

check_activity_body(_Node, {_M, _F, _A}) ->
    ok;
check_activity_body(Node, Fun)
  when is_function(Fun, 0) ->
    case Node =:= node() of
        true ->
            ok;
        false ->
            %% Anonymous functions don't work well when they are called on
            %% other nodes. The other node would have to have the exact same
            %% version of the module (afair), or at least the exact same
            %% version of the anonymous function. All of this obviously makes
            %% backward compatibility hard. So we explicitly MFA's for remote
            %% calls.
            error(non_local_function_disallowed)
    end.

run_body({M, F, A}) ->
    erlang:apply(M, F, A);
run_body(Body)
  when is_function(Body, 0) ->
    Body().

make_activity_token(Domain, DomainToken, Name, Opts, State) ->
    {LeaseNode, _LeaseUUID} = Lease = State#state.local_lease_holder,
    true = (LeaseNode =:= node()),

    #activity_token{lease        = Lease,
                    domain_token = DomainToken,
                    domain       = Domain,
                    name         = Name,
                    options      = Opts}.

make_fresh_activity_token(Domain) ->
    make_fresh_activity_token(Domain, undefined).

make_fresh_activity_token(Domain, undefined) ->
    make_fresh_activity_token(Domain, couch_uuids:random());
make_fresh_activity_token(Domain, DomainToken) ->
    #activity_token{domain       = Domain,
                    domain_token = DomainToken,
                    name         = [],
                    lease        = leader,
                    options      = []}.

set_activity_token(Token) ->
    erlang:put('$leader_activities_token', Token).

get_activity_token() ->
    case erlang:get('$leader_activities_token') of
        undefined ->
            not_activity;
        Token when is_record(Token, activity_token) ->
            {ok, Token}
    end.

get_activity_pid() ->
    {ok, _} = get_activity_token(),

    case async:get_identity() of
        {ok, Async} ->
            Async;
        not_async ->
            self()
    end.

handle_switch_quorum(Domain, Name, NewQuorum, Pid, From, State) ->
    case take_activity(Pid, #activity.pid, State) of
        {ok, Activity, NewState} ->
            ?log_debug("Updating quorum for activity ~p to ~p",
                       [{Domain, Name, Pid}, NewQuorum]),

            gen_server2:reply(From, ok),
            add_activity(Activity#activity{quorum = NewQuorum}, NewState);
        not_found ->
            ?log_debug("Attempt to switch "
                       "quorum by an unknown/stale activity: ~p ",
                       [{Domain, Name, NewQuorum, Pid}]),

            gen_server2:reply(From, nack),
            State
    end.

report_error(Domain, Name, Error) ->
    ?log_error("Activity ~p failed with error ~p", [{Domain, Name}, Error]),
    {leader_activities_error, {Domain, Name}, Error}.

is_verbose(Activity) ->
    not proplists:get_bool(quiet, get_options(Activity)).

get_options(#activity{options = Options}) ->
    Options.

must_bypass_server() ->
    not cluster_compat_mode:is_cluster_vulcan()
        orelse leader_utils:is_new_orchestration_disabled().

pick_implementation(Regular, Bypass, Args) ->
    Impl = case must_bypass_server() of
               true ->
                   Bypass;
               false ->
                   Regular
           end,

    erlang:apply(Impl, Args).

inheritable_options() ->
    [{unsafe, true}].

merge_option({Key, Value}, Options, ParentOptions) ->
    merge_option(Key, _ =:= Value, Options, ParentOptions);
merge_option(Key, Options, ParentOptions)
  when is_atom(Key) ->
    merge_option(Key, functools:const(true), Options, ParentOptions).

merge_option(Key, ValuePred, Options, ParentOptions) ->
    case proplists:is_defined(Key, Options) of
        true ->
            %% Explicitly set in by the caller, so ignoring whatever value the
            %% parent has.
            Options;
        false ->
            NotSet = make_ref(),
            case proplists:get_value(Key, ParentOptions, NotSet) of
                NotSet ->
                    %% Not set by the parent, so ignoring too.
                    Options;
                Value ->
                    case ValuePred(Value) of
                        true ->
                            [{Key, Value} | Options];
                        false ->
                            Options
                    end
            end
    end.

merge_options(Options, ParentOptions) ->
    lists:foldl(merge_option(_, _, ParentOptions),
                Options, inheritable_options()).

get_quorum_nodes() ->
    sets:from_list(ns_cluster_membership:active_nodes()).

handle_update_quorum_nodes(#state{quorum_nodes = QuorumNodes} = State) ->
    ?flush(update_quorum_nodes),

    NewQuorumNodes = get_quorum_nodes(),
    case QuorumNodes =:= NewQuorumNodes of
        true ->
            State;
        false ->
            Added   = sets:subtract(NewQuorumNodes, QuorumNodes),
            Removed = sets:subtract(QuorumNodes, NewQuorumNodes),

            NewState = State#state{quorum_nodes = NewQuorumNodes},
            check_quorums(NewState,
                          {quorum_nodes_changed,
                           {added, sets:to_list(Added)},
                           {removed, sets:to_list(Removed)}})
    end.
