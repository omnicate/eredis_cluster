-module(eredis_cluster).
-behaviour(application).

% Application.
-export([start/2]).
-export([stop/1]).

% API.
-export([start/0, stop/0, connect/1]). % Application Management.

% Generic redis call
-export([q/1, qp/1, qw/2, qk/2, qa/1, transaction/1, transaction/2]).

% Specific redis command implementation
-export([flushdb/0]).

 % Helper functions
-export([update_key/2]).
-export([update_hash_field/3]).
-export([optimistic_locking_transaction/3]).

-include("eredis_cluster.hrl").

-spec start(StartType::application:start_type(), StartArgs::term()) ->
    {ok, pid()}.
start(_Type, _Args) ->
    eredis_cluster_sup:start_link().

-spec stop(State::term()) -> ok.
stop(_State) ->
    ok.

-spec start() -> ok | {error, Reason::term()}.
start() ->
    application:start(?MODULE).

-spec stop() -> ok | {error, Reason::term()}.
stop() ->
    application:stop(?MODULE).

%% =============================================================================
%% @doc Connect to a set of init node, useful if the cluster configuration is
%% not known at startup
%% @end
%% =============================================================================
-spec connect(InitServers::term()) -> Result::term().
connect(InitServers) ->
    eredis_cluster_monitor:connect(InitServers).

%% =============================================================================
%% @doc Wrapper function to execute a pipeline command as a transaction Command
%% (it will add MULTI and EXEC command)
%% @end
%% =============================================================================
-spec transaction(redis_pipeline_command()) -> redis_transaction_result().
transaction(Commands) ->
    Result = q([["multi"]| Commands] ++ [["exec"]]),
    lists:last(Result).

%% =============================================================================
%% @doc Execute a function on a pool worker. This function should be use when
%% transaction method such as WATCH or DISCARD must be used. The pool used to
%% execute the transaction is specified by giving a key that this pool is
%% containing.
%% @end
%% =============================================================================
-spec transaction(fun((Worker::pid()) -> redis_result()), anystring()) -> any().
transaction(Transaction, PoolKey) ->
    Slot = get_key_slot(PoolKey),
    transaction(Transaction, Slot, undefined, 0).

transaction(Transaction, Slot, undefined, _) ->
    query(Transaction, Slot, 0);
transaction(Transaction, Slot, ExpectedValue, Counter) ->
    case query(Transaction, Slot, 0) of
        ExpectedValue ->
            transaction(Transaction, Slot, ExpectedValue, Counter - 1);
        {ExpectedValue, _} ->
            transaction(Transaction, Slot, ExpectedValue, Counter - 1);
        Payload ->
            Payload
    end.

%% =============================================================================
%% @doc Wrapper function for command using pipelined commands
%% @end
%% =============================================================================
-spec qp(redis_pipeline_command()) -> redis_pipeline_result().
qp(Commands) -> q(Commands).

%% =============================================================================
%% @doc This function execute simple or pipelined command on a single redis node
%% the node will be automatically found according to the key used in the command
%% @end
%% =============================================================================
-spec q(redis_command()) -> redis_result().
q(Command) ->
    query(Command).

-spec qk(redis_command(), bitstring()) -> redis_result().
qk(Command, PoolKey) ->
    query(Command, PoolKey).

query(Command) ->
    PoolKey = get_key_from_command(Command),
    query(Command, PoolKey).

query(_, undefined) ->
    {error, invalid_cluster_command};
query(Command, PoolKey) ->
    Slot = get_key_slot(PoolKey),
    Transaction = fun(Worker) -> qw(Worker, Command) end,
    query(Transaction, Slot, 0).

query(_, _, ?REDIS_CLUSTER_REQUEST_TTL) ->
    {error, no_connection};
query(Transaction, Slot, Counter) ->
    %% Throttle retries
    throttle_retries(Counter),

    {Pool, Version} = eredis_cluster_monitor:get_pool_by_slot(Slot),

    case eredis_cluster_pool:transaction(Pool, Transaction) of
        % If we detect a node went down, we should probably refresh the slot
        % mapping.
        {error, no_connection} ->
            eredis_cluster_monitor:refresh_mapping(Version),
            query(Transaction, Slot, Counter+1);

        % If the tcp connection is closed (connection timeout), the redis worker
        % will try to reconnect, thus the connection should be recovered for
        % the next request. We don't need to refresh the slot mapping in this
        % case
        {error, tcp_closed} ->
            query(Transaction, Slot, Counter+1);

        % Redis explicitly say our slot mapping is incorrect, we need to refresh
        % it
        {error, <<"MOVED ", _/binary>>} ->
            eredis_cluster_monitor:refresh_mapping(Version),
            query(Transaction, Slot,  Counter+1);

        Payload ->
            Payload
    end.

-spec throttle_retries(integer()) -> ok.
throttle_retries(0) -> ok;
throttle_retries(_) -> timer:sleep(?REDIS_RETRY_DELAY).

%% =============================================================================
%% @doc Update the value of a key by applying the function passed in the
%% argument. The operation is done atomically
%% @end
%% =============================================================================
-spec update_key(Key::anystring(), UpdateFunction::fun((any()) -> any())) ->
    redis_transaction_result().
update_key(Key, UpdateFunction) ->
    UpdateFunction2 = fun(GetResult) ->
        {ok, Var} = GetResult,
        UpdatedVar = UpdateFunction(Var),
        {[["SET", Key, UpdatedVar]], UpdatedVar}
    end,
    case optimistic_locking_transaction(Key, ["GET", Key], UpdateFunction2) of
        {ok, {_, NewValue}} ->
            {ok, NewValue};
        Error ->
            Error
    end.

%% =============================================================================
%% @doc Update the value of a field stored in a hash by applying the function
%% passed in the argument. The operation is done atomically
%% @end
%% =============================================================================
-spec update_hash_field(Key::anystring(), Field::anystring(),
    UpdateFunction::fun((any()) -> any())) -> redis_transaction_result().
update_hash_field(Key, Field, UpdateFunction) ->
    UpdateFunction2 = fun(GetResult) ->
        {ok, Var} = GetResult,
        UpdatedVar = UpdateFunction(Var),
        {[["HSET", Key, Field, UpdatedVar]], UpdatedVar}
    end,
    case optimistic_locking_transaction(Key, ["HGET", Key, Field], UpdateFunction2) of
        {ok, {[FieldPresent], NewValue}} ->
            {ok, {FieldPresent, NewValue}};
        Error ->
            Error
    end.

%% =============================================================================
%% @doc Optimistic locking transaction helper, based on Redis documentation :
%% http://redis.io/topics/transactions
%% @end
%% =============================================================================
-spec optimistic_locking_transaction(Key::anystring(), redis_command(),
    UpdateFunction::fun((redis_result()) -> redis_pipeline_command())) ->
        {redis_transaction_result(), any()}.
optimistic_locking_transaction(WatchedKey, GetCommand, UpdateFunction) ->
    Slot = get_key_slot(WatchedKey),
    Transaction = fun(Worker) ->
        %% Watch given key
        qw(Worker,["WATCH", WatchedKey]),
        %% Get necessary information for the modifier function
        GetResult = qw(Worker, GetCommand),
        %% Execute the pipelined command as a redis transaction
        {UpdateCommand, Result} = case UpdateFunction(GetResult) of
            {Command, Var} ->
                {Command, Var};
            Command ->
                {Command, undefined}
        end,
        RedisResult = qw(Worker, [["MULTI"]] ++ UpdateCommand ++ [["EXEC"]]),
        {lists:last(RedisResult), Result}
    end,
	case transaction(Transaction, Slot, {ok, undefined}, ?OL_TRANSACTION_TTL) of
        {{ok, undefined}, _} ->
            {error, resource_busy};
        {{ok, TransactionResult}, UpdateResult} ->
            {ok, {TransactionResult, UpdateResult}};
        {Error, _} ->
            Error
    end.

%% =============================================================================
%% @doc Perform a given query on all node of a redis cluster
%% @end
%% =============================================================================
-spec qa(redis_command()) -> ok | {error, Reason::bitstring()}.
qa(Command) ->
    Pools = eredis_cluster_monitor:get_all_pools(),
    Transaction = fun(Worker) -> qw(Worker, Command) end,
    [eredis_cluster_pool:transaction(Pool, Transaction) || Pool <- Pools].

%% =============================================================================
%% @doc Wrapper function to be used for direct call to a pool worker in the
%% function passed to the transaction/2 method
%% @end
%% =============================================================================
-spec qw(Worker::pid(), redis_command()) -> redis_result().
qw(Worker, Command) ->
    eredis_cluster_pool_worker:query(Worker, Command).

%% =============================================================================
%% @doc Perform flushdb command on each node of the redis cluster
%% @end
%% =============================================================================
-spec flushdb() -> ok | {error, Reason::bitstring()}.
flushdb() ->
    Result = qa(["FLUSHDB"]),
    case proplists:lookup(error,Result) of
        none ->
            ok;
        Error ->
            Error
    end.

%% =============================================================================
%% @doc Return the hash slot from the key
%% @end
%% =============================================================================
-spec get_key_slot(Key::anystring()) -> Slot::integer().
get_key_slot(Key) when is_bitstring(Key) ->
    get_key_slot(bitstring_to_list(Key));
get_key_slot(Key) ->
    KeyToBeHased = case string:chr(Key,${) of
        0 ->
            Key;
        Start ->
            case string:chr(string:substr(Key,Start+1),$}) of
                0 ->
                    Key;
                Length ->
                    if
                        Length =:= 1 ->
                            Key;
                        true ->
                            string:substr(Key,Start+1,Length-1)
                    end
            end
    end,
    eredis_cluster_hash:hash(KeyToBeHased).

%% =============================================================================
%% @doc Return the first key in the command arguments.
%% In a normal query, the second term will be returned
%%
%% If it is a pipeline query we will use the second term of the first term, we
%% will assume that all keys are in the same server and the query can be
%% performed
%%
%% If the pipeline query starts with multi (transaction), we will look at the
%% second term of the second command
%%
%% For eval and evalsha command we will look at the fourth term.
%%
%% For commands that don't make sense in the context of cluster
%% return value will be undefined.
%% @end
%% =============================================================================
-spec get_key_from_command(redis_command()) -> string() | undefined.
get_key_from_command([[X|Y]|Z]) when is_bitstring(X) ->
    get_key_from_command([[bitstring_to_list(X)|Y]|Z]);
get_key_from_command([[X|Y]|Z]) when is_list(X) ->
    case string:to_lower(X) of
        "multi" ->
            get_key_from_command(Z);
        _ ->
            get_key_from_command([X|Y])
    end;
get_key_from_command([Term1,Term2|Rest]) when is_bitstring(Term1) ->
    get_key_from_command([bitstring_to_list(Term1),Term2|Rest]);
get_key_from_command([Term1,Term2|Rest]) when is_bitstring(Term2) ->
    get_key_from_command([Term1,bitstring_to_list(Term2)|Rest]);
get_key_from_command([Term1,Term2|Rest]) ->
    case string:to_lower(Term1) of
        "info" ->
            undefined;
        "config" ->
            undefined;
        "shutdown" ->
            undefined;
        "slaveof" ->
            undefined;
        "eval" ->
            get_key_from_rest(Rest);
        "evalsha" ->
            get_key_from_rest(Rest);
        _ ->
            Term2
    end;
get_key_from_command(_) ->
    undefined.

%% =============================================================================
%% @doc Get key for command where the key is in th 4th position (eval and
%% evalsha commands)
%% @end
%% =============================================================================
-spec get_key_from_rest([anystring()]) -> string() | undefined.
get_key_from_rest([_,KeyName|_]) when is_bitstring(KeyName) ->
    bitstring_to_list(KeyName);
get_key_from_rest([_,KeyName|_]) when is_list(KeyName) ->
    KeyName;
get_key_from_rest(_) ->
    undefined.
