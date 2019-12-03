-module(els_indexer).

-callback index(els_document:document()) -> ok.

%% TODO: Solve API mix (gen_server and not)
%% API
-export([ find_and_index_file/1
        , find_and_index_file/2
        , index_file/2
        , index/1
        , index_dir/1
        , start_link/0
        , index_paths/0
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , terminate/2
        ]).

%%==============================================================================
%% Includes
%%==============================================================================
-include("erlang_ls.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%%==============================================================================
%% Types
%%==============================================================================
-type state() :: #{}.

%%==============================================================================
%% Macros
%%==============================================================================
-define(SERVER, ?MODULE).

%%==============================================================================
%% Exported functions
%%==============================================================================
-spec find_and_index_file(string()) ->
   {ok, uri()} | {error, any()}.
find_and_index_file(FileName) ->
  find_and_index_file(FileName, async).

-spec find_and_index_file(string(), async | sync) ->
   {ok, uri()} | {error, any()}.
find_and_index_file(FileName, SyncAsync) ->
  SearchPaths = els_config:get(search_paths),
  case file:path_open(SearchPaths, list_to_binary(FileName), [read]) of
    {ok, IoDevice, FullName} ->
      %% TODO: Avoid opening file twice
      file:close(IoDevice),
      index_file(FullName, SyncAsync);
    {error, Error} ->
      {error, Error}
  end.

-spec index_file(binary(), sync | async) -> {ok, uri()}.
index_file(Path, SyncAsync) ->
  try_index_file(Path, SyncAsync),
  {ok, els_uri:uri(Path)}.

-spec index(els_document:document()) -> ok.
index(Document) ->
  Uri    = els_document:uri(Document),
  ok     = els_db:store(documents, Uri, Document),
  Module = els_uri:module(Uri),
  ok = els_db:store(modules, Module, Uri),
  Specs  = els_document:points_of_interest(Document, [spec]),
  [els_db:store(signatures, {Module, F, A}, Tree) ||
    #{id := {F, A}, data := Tree} <- Specs],
  Kinds = [application, implicit_fun],
  POIs  = els_document:points_of_interest(Document, Kinds),
  purge_uri_references(Uri),
  [register_reference(Uri, POI) || POI <- POIs],
  ok.

-spec index_paths() -> ok.
index_paths() ->
  gen_server:cast(?SERVER, {index_paths}).

-spec index_dir(string()) -> {non_neg_integer(), non_neg_integer()}.
index_dir(Dir) ->
  lager:info("Indexing directory. [dir=~s]", [Dir]),
  F = fun(FileName, {Succeeded, Failed}) ->
          case try_index_file(list_to_binary(FileName), async) of
            ok              -> {Succeeded + 1, Failed};
            {error, _Error} -> {Succeeded, Failed + 1}
          end
      end,
  Filter = fun(Path) ->
               Ext = filename:extension(Path),
               lists:member(Ext, [".erl", ".hrl"])
           end,

  {Time, {Succeeded, Failed}} = timer:tc( els_utils
                                        , fold_files
                                        , [ F
                                          , Filter
                                          , Dir
                                          , {0, 0}
                                          ]
                                        ),
  lager:info("Finished indexing directory. [dir=~s] [time=~p] "
             "[succeeded=~p] "
             "[failed=~p]", [Dir, Time/1000/1000, Succeeded, Failed]),
  {Succeeded, Failed}.

-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, {}, []).

%%==============================================================================
%% gen_server Callback Functions
%%==============================================================================

-spec init({}) -> {ok, state()}.
init({}) ->
  %% TODO: Optionally configure number of workers from args
  Workers = application:get_env(els_app, indexers, 10),
  {ok, _Pool} = wpool:start_sup_pool(indexers, [ {workers, Workers} ]),
  {ok, #{}}.

-spec handle_call(any(), any(), state()) ->
  {noreply, state()}.
handle_call(_Request, _From, State) ->
  {noreply, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast({index_paths}, State) ->
  [index_dir(Dir) || Dir <- els_config:get(index_paths)],
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_, _State) ->
  wpool:stop_sup_pool(indexers),
  ok.

%%==============================================================================
%% Internal functions
%%==============================================================================

%% @edoc Try indexing a file.
-spec try_index_file(binary(), sync | async) -> ok | {error, any()}.
try_index_file(FullName, SyncAsync) ->
  try
    lager:debug("Indexing file. [filename=~s]", [FullName]),
    {ok, Text} = file:read_file(FullName),
    Uri        = els_uri:uri(FullName),
    Document   = els_document:create(Uri, Text),
    ok         = index_document(Document, SyncAsync)
  catch Type:Reason:St ->
      lager:error("Error indexing file "
                  "[filename=~s] "
                  "~p:~p:~p", [FullName, Type, Reason, St]),
      {error, {Type, Reason}}
  end.

-spec index_document(els_document:document(), async | sync) -> ok.
index_document(Document, async) ->
  ok = wpool:cast(indexers, {?MODULE, index, [Document]});
index_document(Document, sync) ->
  %% Don't use the pool for synchronous indexing
  ok = index(Document).

%% TODO: Specific for references

-type ref_key()   :: {any(), any(), any()}. %% {M, F, A}
-type ref_value() :: #{ uri := uri(), range := poi_range() }.

-spec register_reference(uri(), poi()) -> ok.
register_reference(Uri, #{id := {M, F, A}, range := Range}) ->
  Ref = #{uri => Uri, range => Range},
  add_reference({M, F, A}, Ref),
  ok;
register_reference(Uri, #{id := {F, A}, range := Range}) ->
  Ref = #{uri => Uri, range => Range},
  M = els_uri:module(Uri),
  add_reference({M, F, A}, Ref),
  ok.

-spec add_reference(ref_key(), ref_value()) -> ok.
add_reference(Key, Value) ->
  ok = els_db:store(references, Key, Value).

%% @edoc Remove all references to a given uri()
-spec purge_uri_references(uri()) -> ok.
purge_uri_references(Uri) ->
    MatchSpec = ets:fun2ms(fun({_K, #{uri => U}}) -> U =:= Uri end),
    _DeletedCount = ets:select_delete(references, MatchSpec),
    ok.
