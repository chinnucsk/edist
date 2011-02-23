%%% -------------------------------------------------------------------
%%% Author  : ghaskins
%%% -------------------------------------------------------------------
-module(edist_agent_sup).
-behaviour(supervisor).

-export([start_link/1, start_child/1]).

%% --------------------------------------------------------------------
%% Internal exports
%% --------------------------------------------------------------------
-export([
        init/1
        ]).

-define(SERVER, ?MODULE).

start_link(Args) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Args).

start_child(ChildSpec) ->
    supervisor:start_child(?MODULE, ChildSpec).

init([App, Path]) ->
    {ok,{{one_for_all,0,1},
	 [
	  {'edist-agent',
	   {edist_agent,start_link,[]},
	   permanent, 2000, worker,[edist_agent]},
	  {'edist-connection',
	   {connection_fsm,start_link,[]},
	   permanent, 2000, worker,[connection_fsm]},
	  {'edist-subscription',
	   {subscription_fsm,start_link,[App, Path]},
	   permanent, 2000, worker,[subscrition_fsm]}
	 ]
	}
    }.

