%%%-------------------------------------------------------------------
%%% @copyright (C) 2016, 2600Hz INC
%%%
%%% @contributors
%%%-------------------------------------------------------------------

-module(webhooks_object).

-export([init/0
        ,bindings_and_responders/0
        ,account_bindings/1
        ,handle_event/2
        ]).

-include("webhooks.hrl").
-include_lib("kazoo_amqp/include/kapi_conf.hrl").
-include_lib("kazoo_documents/include/doc_types.hrl").

-define(ID, kz_util:to_binary(?MODULE)).
-define(NAME, <<"object">>).
-define(DESC, <<"Receive notifications when objects in Kazoo are changed">>).

-define(OBJECT_TYPES
       ,kapps_config:get(?APP_NAME
                        ,<<"object_types">>
                        ,?DOC_TYPES
                        )
       ).

-define(TYPE_MODIFIER
       ,kz_json:from_list(
          [{<<"type">>, <<"array">>}
          ,{<<"description">>, <<"A list of object types to handle">>}
          ,{<<"items">>, ?OBJECT_TYPES}
          ])
       ).

-define(ACTIONS_MODIFIER
       ,kz_json:from_list(
          [{<<"type">>, <<"array">>}
          ,{<<"description">>, <<"A list of object actions to handle">>}
          ,{<<"items">>, ?DOC_ACTIONS}
          ])
       ).

-define(MODIFIERS
       ,kz_json:from_list(
          [{<<"type">>, ?TYPE_MODIFIER}
          ,{<<"action">>, ?ACTIONS_MODIFIER}
          ])
       ).

-define(METADATA
       ,kz_json:from_list(
          [{<<"_id">>, ?ID}
          ,{<<"name">>, ?NAME}
          ,{<<"description">>, ?DESC}
          ,{<<"modifiers">>, ?MODIFIERS}
          ])
       ).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    webhooks_util:init_metadata(?ID, ?METADATA).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec bindings_and_responders() -> {gen_listener:bindings(), gen_listener:responders()}.
bindings_and_responders() ->
    Bindings = bindings(),
    Responders = [{{?MODULE, 'handle_event'}, [{<<"configuration">>, <<"*">>}]}],
    {Bindings, Responders}.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec account_bindings(ne_binary()) -> gen_listener:bindings().
account_bindings(_AccountId) -> [].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec handle_event(kz_json:object(), kz_proplist()) -> any().
handle_event(JObj, _Props) ->
    kz_util:put_callid(JObj),
    'true' = kapi_conf:doc_update_v(JObj),

    AccountId = find_account_id(JObj),
    case webhooks_util:find_webhooks(?NAME, AccountId) of
        [] ->
            lager:debug("no hooks to handle ~s for ~s"
                       ,[kz_api:event_name(JObj), AccountId]
                       );
        Hooks ->
            Event = format_event(JObj, AccountId),
            Action = kz_api:event_name(JObj),
            Type = kapi_conf:get_type(JObj),
            Filtered = [Hook || Hook <- Hooks, match_action_type(Hook, Action, Type)],
            webhooks_util:fire_hooks(Event, Filtered)
    end.

-spec match_action_type(webhook(), api_binary(), api_binary()) -> boolean().
match_action_type(#webhook{hook_event = ?NAME
                          ,custom_data='undefined'
                          }, _Action, _Type) -> 'true';
match_action_type(#webhook{hook_event = ?NAME
                          ,custom_data=JObj
                          }, Action, Type) ->
    kz_json:get_value(<<"action">>, JObj) =:= Action
        andalso kz_json:get_value(<<"type">>, JObj) =:= Type;
match_action_type(#webhook{}, _Action, _Type) -> 'true'.

%%%===================================================================
%%% Internal functions
%%%===================================================================


%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec bindings() -> gen_listener:bindings().
bindings() ->
    [{'conf', [{'restrict_to', ['doc_updates']}]}].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec format_event(kz_json:object(), ne_binary()) -> kz_json:object().
format_event(JObj, AccountId) ->
    kz_json:from_list(
      props:filter_undefined(
        [{<<"id">>, kapi_conf:get_id(JObj)}
        ,{<<"account_id">>, AccountId}
        ,{<<"action">>, kz_api:event_name(JObj)}
        ,{<<"type">>, kapi_conf:get_type(JObj)}
        ])
     ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec find_account_id(kz_json:object()) -> ne_binary().
find_account_id(JObj) ->
    case kapi_conf:get_account_id(JObj) of
        'undefined' ->
            kz_util:format_account_id(kapi_conf:get_account_db(JObj), 'raw');
        AccountId -> AccountId
    end.
