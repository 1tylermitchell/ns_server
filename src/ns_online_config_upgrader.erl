%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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

-module(ns_online_config_upgrader).

-include("ns_common.hrl").

-export([upgrade_config/1]).

upgrade_config(NewVersion) ->
    true = (NewVersion =< ?LATEST_VERSION_NUM),

    ok = ns_config:upgrade_config_explicitly(
           fun (Config) ->
                   do_upgrade_config(Config, NewVersion)
           end).

do_upgrade_config(Config, FinalVersion) ->
    case ns_config:search(Config, cluster_compat_version) of
        false ->
            [{set, cluster_compat_version, [2, 0]}];
        {value, undefined} ->
            [{set, cluster_compat_version, [2, 0]}];
        {value, FinalVersion} ->
            [];
        {value, [2, 0]} ->
            [{set, cluster_compat_version, [2, 5]} |
             upgrade_config_from_2_0_to_2_5(Config)];
        {value, [2, 5]} ->
            [{set, cluster_compat_version, [3, 0]} |
             upgrade_config_from_2_5_to_3_0(Config)];
        {value, [3, 0]} ->
            [{set, cluster_compat_version, [4, 0]} |
             upgrade_config_from_3_0_to_4_0(Config)];
        {value, [4, 0]} ->
            [{set, cluster_compat_version, [4, 1]} |
             upgrade_config_from_4_0_to_4_1(Config)];
        {value, [4, 1]} ->
            [{set, cluster_compat_version, ?WATSON_VERSION_NUM} |
             upgrade_config_from_4_1_to_watson(Config)]
    end.

upgrade_config_from_2_0_to_2_5(Config) ->
    ?log_info("Performing online config upgrade to 2.5 version"),
    create_server_groups(Config).

upgrade_config_from_2_5_to_3_0(Config) ->
    ?log_info("Performing online config upgrade to 3.0 version"),
    delete_unwanted_per_node_keys(Config) ++
        ns_config_auth:upgrade(Config).

upgrade_config_from_3_0_to_4_0(Config) ->
    ?log_info("Performing online config upgrade to 4.0 version"),
    goxdcr_upgrade:config_upgrade(Config) ++
        index_settings_manager:config_upgrade().

upgrade_config_from_4_0_to_4_1(Config) ->
    ?log_info("Performing online config upgrade to 4.1 version"),
    create_service_maps(Config, [n1ql, index]).

upgrade_config_from_4_1_to_watson(Config) ->
    ?log_info("Performing online config upgrade to ~s version",
              [misc:pretty_version(?WATSON_VERSION_NUM)]),
    RV = create_service_maps(Config, [fts]) ++
        menelaus_roles:upgrade_users(Config),
    index_settings_manager:config_upgrade_to_watson(Config) ++ RV.

delete_unwanted_per_node_keys(Config) ->
    NodesWanted = ns_node_disco:nodes_wanted(Config),
    R = ns_config:fold(
          fun ({node, Node, _} = K, _, Acc) ->
                  case lists:member(Node, NodesWanted) of
                      true ->
                          Acc;
                      false ->
                          sets:add_element({delete, K}, Acc)
                  end;
              (_, _, Acc) ->
                  Acc
          end, sets:new(), Config),

    sets:to_list(R).

create_server_groups(Config) ->
    {value, Nodes} = ns_config:search(Config, nodes_wanted),
    [{set, server_groups, [[{uuid, <<"0">>},
                            {name, <<"Group 1">>},
                            {nodes, Nodes}]]}].

create_service_maps(Config, Services) ->
    ActiveNodes = ns_cluster_membership:active_nodes(Config),
    Maps = [{S, ns_cluster_membership:service_nodes(Config, ActiveNodes, S)} ||
                S <- Services],
    [{set, {service_map, Service}, Map} || {Service, Map} <- Maps].
