defmodule Ecto.Adapters.SQL do
  @moduledoc """
  Behaviour and implementation for SQL adapters.

  The implementation for SQL adapter relies on `DBConnection`
  to provide pooling, prepare, execute and more.

  Developers that use `Ecto.Adapters.SQL` should implement
  the callbacks required both by this module and the ones
  from `Ecto.Adapters.SQL.Connection` for handling connections
  and performing queries.
  """

  @doc false
  defmacro __using__(adapter) do
    quote do
      @behaviour Ecto.Adapter
      @behaviour Ecto.Adapter.Migration
      @behaviour Ecto.Adapter.Transaction

      @conn __MODULE__.Connection
      @adapter unquote(adapter)

      @doc false
      defmacro __before_compile__(env) do
        Ecto.Adapters.SQL.__before_compile__(@adapter, env)
      end

      @doc false
      def ensure_all_started(config, type) do
        Ecto.Adapters.SQL.ensure_all_started(@adapter, config, type)
      end

      @doc false
      def init(config) do
        Ecto.Adapters.SQL.init(@conn, @adapter, config)
      end

      ## Types

      @doc false
      def autogenerate(:id),        do: nil
      def autogenerate(:embed_id),  do: Ecto.UUID.generate()
      def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

      @doc false
      def loaders({:embed, _} = type, _), do: [&Ecto.Adapters.SQL.load_embed(type, &1)]
      def loaders(:binary_id, type),      do: [Ecto.UUID, type]
      def loaders(_, type),               do: [type]

      @doc false
      def dumpers({:embed, _} = type, _), do: [&Ecto.Adapters.SQL.dump_embed(type, &1)]
      def dumpers(:binary_id, type),      do: [type, Ecto.UUID]
      def dumpers(_, type),               do: [type]

      ## Query

      @doc false
      def prepare(:all, query) do
        {:cache, {System.unique_integer([:positive]), IO.iodata_to_binary(@conn.all(query))}}
      end

      def prepare(:update_all, query) do
        {:cache, {System.unique_integer([:positive]), IO.iodata_to_binary(@conn.update_all(query))}}
      end

      def prepare(:delete_all, query) do
        {:cache, {System.unique_integer([:positive]), IO.iodata_to_binary(@conn.delete_all(query))}}
      end

      @doc false
      def execute(adapter_meta, query_meta, query, params, opts) do
        Ecto.Adapters.SQL.execute(adapter_meta, query_meta, query, params, opts)
      end

      @doc false
      def stream(adapter_meta, query_meta, query, params, opts) do
        Ecto.Adapters.SQL.stream(adapter_meta, query_meta, query, params, opts)
      end

      @doc false
      def insert_all(adapter_meta, schema_meta, header, rows, on_conflict, returning, opts) do
        Ecto.Adapters.SQL.insert_all(adapter_meta, schema_meta, @conn, header, rows, on_conflict, returning, opts)
      end

      @doc false
      def insert(adapter_meta, %{source: source, prefix: prefix}, params,
                 {kind, conflict_params, _} = on_conflict, returning, opts) do
        {fields, values} = :lists.unzip(params)
        sql = @conn.insert(prefix, source, fields, [fields], on_conflict, returning)
        Ecto.Adapters.SQL.struct(adapter_meta, @conn, sql, {:insert, source, []}, values ++ conflict_params, kind, returning, opts)
      end

      @doc false
      def update(adapter_meta, %{source: source, prefix: prefix}, fields, params, returning, opts) do
        {fields, field_values} = :lists.unzip(fields)
        filter_values = params |> Keyword.values() |> Enum.reject(&is_nil(&1))
        sql = @conn.update(prefix, source, fields, params, returning)
        Ecto.Adapters.SQL.struct(adapter_meta, @conn, sql, {:update, source, params}, field_values ++ filter_values, :raise, returning, opts)
      end

      @doc false
      def delete(adapter_meta, %{source: source, prefix: prefix}, params, opts) do
        filter_values = params |> Keyword.values() |> Enum.reject(&is_nil(&1))
        sql = @conn.delete(prefix, source, params, [])
        Ecto.Adapters.SQL.struct(adapter_meta, @conn, sql, {:delete, source, params}, filter_values, :raise, [], opts)
      end

      ## Transaction

      @doc false
      def transaction(meta, opts, fun) do
        Ecto.Adapters.SQL.transaction(meta, opts, fun)
      end

      @doc false
      def in_transaction?(meta) do
        Ecto.Adapters.SQL.in_transaction?(meta)
      end

      @doc false
      def rollback(meta, value) do
        Ecto.Adapters.SQL.rollback(meta, value)
      end

      ## Migration

      @doc false
      def execute_ddl(meta, definition, opts) do
        Ecto.Adapters.SQL.execute_ddl(meta, @conn.execute_ddl(definition), opts)
      end

      @doc false
      def lock_for_migrations(meta, query, opts, fun) do
        Ecto.Adapters.SQL.lock_for_migrations(meta, query, opts, fun)
      end

      defoverridable [prepare: 2, execute: 5, insert: 6, update: 6, delete: 4, insert_all: 7,
                      execute_ddl: 3, loaders: 2, dumpers: 2, autogenerate: 1,
                      ensure_all_started: 2, lock_for_migrations: 4]
    end
  end

  @doc """
  Converts the given query to SQL according to its kind and the
  adapter in the given repository.

  ## Examples

  The examples below are meant for reference. Each adapter will
  return a different result:

      iex> Ecto.Adapters.SQL.to_sql(:all, repo, Post)
      {"SELECT p.id, p.title, p.inserted_at, p.created_at FROM posts as p", []}

      iex> Ecto.Adapters.SQL.to_sql(:update_all, repo,
                                    from(p in Post, update: [set: [title: ^"hello"]]))
      {"UPDATE posts AS p SET title = $1", ["hello"]}

  This function is also available under the repository with name `to_sql`:

      iex> Repo.to_sql(:all, Post)
      {"SELECT p.id, p.title, p.inserted_at, p.created_at FROM posts as p", []}

  """
  @spec to_sql(:all | :update_all | :delete_all, Ecto.Repo.t, Ecto.Queryable.t) ::
               {String.t, [term]}
  def to_sql(kind, repo, queryable) do
    case Ecto.Adapter.prepare_query(kind, repo, queryable) do
      {{:cached, _reset, {_id, cached}}, params} ->
        {String.Chars.to_string(cached), params}

      {{:cache, _update, {_id, prepared}}, params} ->
        {prepared, params}

      {{:nocache, {_id, prepared}}, params} ->
        {prepared, params}
    end
  end

  @doc """
  Returns a stream that runs a custom SQL query on given repo when reduced.

  In case of success it is a enumerable containing maps with at least two keys:

    * `:num_rows` - the number of rows affected

    * `:rows` - the result set as a list. `nil` may be returned
      instead of the list if the command does not yield any row
      as result (but still yields the number of affected rows,
      like a `delete` command without returning would)

  In case of failure it raises an exception.

  If the adapter supports a collectable stream, the stream may also be used as
  the collectable in `Enum.into/3`. Behaviour depends on the adapter.

  ## Options

    * `:timeout` - The time in milliseconds to wait for a query to finish,
      `:infinity` will wait indefinitely (default: 15_000)
    * `:pool_timeout` - The time in milliseconds to wait for a call to the pool
      to finish, `:infinity` will wait indefinitely (default: 5_000)
    * `:log` - When false, does not log the query
    * `:max_rows` - The number of rows to load from the database as we stream

  ## Examples

      iex> Ecto.Adapters.SQL.stream(MyRepo, "SELECT $1::integer + $2", [40, 2]) |> Enum.to_list()
      [%{rows: [[42]], num_rows: 1}]

  """
  @spec stream(Ecto.Repo.t, String.t, [term], Keyword.t) :: Enum.t
  def stream(repo, sql, params \\ [], opts \\ []) do
    repo
    |> Ecto.Adapter.lookup_meta()
    |> Ecto.Adapters.SQL.Stream.build(sql, params, opts)
  end

  @doc """
  Same as `query/4` but raises on invalid queries.
  """
  @spec query!(Ecto.Repo.t | Ecto.Adapter.adapter_meta, String.t, [term], Keyword.t) ::
               %{:rows => nil | [[term] | binary],
                 :num_rows => non_neg_integer,
                 optional(atom) => any}
               | no_return
  def query!(repo, sql, params \\ [], opts \\ []) do
    case query(repo, sql, params, opts) do
      {:ok, result} -> result
      {:error, err} -> raise err
    end
  end

  @doc """
  Runs custom SQL query on given repo.

  In case of success, it must return an `:ok` tuple containing
  a map with at least two keys:

    * `:num_rows` - the number of rows affected

    * `:rows` - the result set as a list. `nil` may be returned
      instead of the list if the command does not yield any row
      as result (but still yields the number of affected rows,
      like a `delete` command without returning would)

  ## Options

    * `:timeout` - The time in milliseconds to wait for a query to finish,
      `:infinity` will wait indefinitely. (default: 15_000)
    * `:pool_timeout` - The time in milliseconds to wait for a call to the pool
      to finish, `:infinity` will wait indefinitely. (default: 5_000)

    * `:log` - When false, does not log the query

  ## Examples

      iex> Ecto.Adapters.SQL.query(MyRepo, "SELECT $1::integer + $2", [40, 2])
      {:ok, %{rows: [[42]], num_rows: 1}}

  For convenience, this function is also available under the repository:

      iex> MyRepo.query("SELECT $1::integer + $2", [40, 2])
      {:ok, %{rows: [[42]], num_rows: 1}}

  """
  @spec query(Ecto.Repo.t | Ecto.Adapter.adapter_meta, String.t, [term], Keyword.t) ::
              {:ok, %{:rows => nil | [[term] | binary],
                      :num_rows => non_neg_integer,
                      optional(atom) => any}}
              | {:error, Exception.t}
  def query(repo, sql, params \\ [], opts \\ [])

  def query(repo, sql, params, opts) when is_atom(repo) do
    query(Ecto.Adapter.lookup_meta(repo), sql, params, opts)
  end

  def query(adapter_meta, sql, params, opts) do
    sql_call(adapter_meta, :execute, [sql], params, opts)
  end

  defp sql_call({pool, {loggers, sql, default_opts}}, callback, args, params, opts) do
    conn = get_conn(pool) || pool
    opts = with_log(loggers, params, opts ++ default_opts)
    args = args ++ [params, opts]

    try do
      apply(sql, callback, [conn | args])
    rescue
      err in DBConnection.OwnershipError ->
        message = err.message <> "\nSee Ecto.Adapters.SQL.Sandbox docs for more information."
        reraise %{err | message: message}, System.stacktrace
    end
  end

  defp put_source(opts, %{sources: sources}) when is_binary(elem(elem(sources, 0), 0)) do
    {source, _, _} = elem(sources, 0)
    Keyword.put(opts, :source, source)
  end

  defp put_source(opts, _) do
    opts
  end

  ## Callbacks

  @doc false
  def __before_compile__(adapter, _env) do
    case Application.get_env(:ecto, :json_library) do
      nil ->
        :ok

      Jason ->
        IO.warn """
        Jason is the default :json_library in Ecto 3.0.
        You no longer need to configure it explicitly,
        please remove this line from your config files:

            config :ecto, :json_library, Jason

        """

      value ->
        IO.warn """
        The :json_library configuration for the :ecto application is deprecated.
        Please configure the :json_library in the adapter instead:

            config #{inspect adapter}, :json_library, #{inspect value}

        """
    end

    quote do
      @doc """
      A convenience function for SQL-based repositories that executes the given query.

      See `Ecto.Adapters.SQL.query/4` for more information.
      """
      def query(sql, params \\ [], opts \\ []) do
        Ecto.Adapters.SQL.query(__MODULE__, sql, params, opts)
      end

      @doc """
      A convenience function for SQL-based repositories that executes the given query.

      See `Ecto.Adapters.SQL.query!/4` for more information.
      """
      def query!(sql, params \\ [], opts \\ []) do
        Ecto.Adapters.SQL.query!(__MODULE__, sql, params, opts)
      end

      @doc """
      A convenience function for SQL-based repositories that translates the given query to SQL.

      See `Ecto.Adapters.SQL.to_sql/3` for more information.
      """
      def to_sql(operation, queryable) do
        Ecto.Adapters.SQL.to_sql(operation, __MODULE__, queryable)
      end
    end
  end

  @doc false
  def ensure_all_started(adapter, config, type) do
    pool_config = pool_config(config)

    with {:ok, from_pool} <- DBConnection.ensure_all_started(pool_config, type),
         {:ok, from_adapter} <- Application.ensure_all_started(adapter, type),
         # We always return the adapter to force it to be restarted if necessary
         do: {:ok, from_pool ++ List.delete(from_adapter, adapter) ++ [adapter]}
  end

  @doc false
  def init(connection, adapter, config) do
    unless Code.ensure_loaded?(connection) do
      raise """
      could not find #{inspect connection}.

      Please verify you have added #{inspect adapter} as a dependency:

          {#{inspect adapter}, ">= 0.0.0"}

      And remember to recompile Ecto afterwards by cleaning the current build:

          mix deps.clean --build ecto
      """
    end

    loggers = Keyword.fetch!(config, :loggers)
    pool_config = pool_config(config)
    {:ok, connection.child_spec(pool_config), {loggers, connection, pool_config}}
  end

  defp pool_config(config) do
    config
    |> Keyword.drop([:loggers, :priv, :url, :name])
    |> Keyword.update(:pool, DBConnection.Poolboy, &normalize_pool/1)
  end

  defp normalize_pool(pool) do
    if Code.ensure_loaded?(pool) && function_exported?(pool, :unboxed_run, 2) do
      DBConnection.Ownership
    else
      pool
    end
  end

  ## Types

  @doc false
  def load_embed(type, value) do
    Ecto.Type.load(type, value, fn
      {:embed, _} = type, value -> load_embed(type, value)
      type, value -> Ecto.Type.cast(type, value)
    end)
  end

  @doc false
  def dump_embed(type, value) do
    Ecto.Type.dump(type, value, fn
      {:embed, _} = type, value -> dump_embed(type, value)
      _type, value -> {:ok, value}
    end)
  end

  ## Query

  @doc false
  def insert_all(adapter_meta, schema_meta, conn, header, rows, on_conflict, returning, opts) do
    %{source: source, prefix: prefix} = schema_meta
    {_, conflict_params, _} = on_conflict
    {rows, params} = unzip_inserts(header, rows)
    sql = conn.insert(prefix, source, header, rows, on_conflict, returning)

    %{num_rows: num, rows: rows} =
      query!(adapter_meta, sql, Enum.reverse(params) ++ conflict_params, opts)

    {num, rows}
  end

  defp unzip_inserts(header, rows) do
    Enum.map_reduce rows, [], fn fields, params ->
      Enum.map_reduce header, params, fn key, acc ->
        case :lists.keyfind(key, 1, fields) do
          {^key, value} -> {key, [value|acc]}
          false -> {nil, acc}
        end
      end
    end
  end

  @doc false
  def execute(adapter_meta, query_meta, prepared, params, opts) do
    %{num_rows: num, rows: rows} =
      do_execute(adapter_meta, prepared, params, put_source(opts, query_meta))

    {num, rows}
  end

  defp do_execute(adapter_meta, {:cache, update, {id, prepared}}, params, opts) do
    execute_and_cache(adapter_meta, id, update, prepared, params, opts)
  end

  defp do_execute(adapter_meta, {:cached, reset, {id, cached}}, params, opts) do
    execute_or_reset(adapter_meta, id, reset, cached, params, opts)
  end

  defp do_execute(adapter_meta, {:nocache, {_id, prepared}}, params, opts) do
    case sql_call(adapter_meta, :execute, [prepared], params, opts) do
      {:ok, res}    -> res
      {:error, err} -> raise err
    end
  end

  defp execute_and_cache(adapter_meta, id, update, prepared, params, opts) do
    name = "ecto_" <> Integer.to_string(id)

    case sql_call(adapter_meta, :prepare_execute, [name, prepared], params, opts) do
      {:ok, query, result} ->
        update.({id, query})
        result
      {:error, err} ->
        raise err
    end
  end

  defp execute_or_reset(adapter_meta, id, reset, cached, params, opts) do
    case sql_call(adapter_meta, :execute, [cached], params, opts) do
      {:ok, result} ->
        result
      {:error, err} ->
        raise err
      {:reset, err} ->
        reset.({id, String.Chars.to_string(cached)})
        raise err
    end
  end

  @doc false
  def stream(adapter_meta, query_meta, prepared, params, opts) do
    do_stream(adapter_meta, prepared, params, put_source(opts, query_meta))
  end

  defp do_stream(adapter_meta, {:cache, _, {_, prepared}}, params, opts) do
    prepare_stream(adapter_meta, prepared, params, opts)
  end

  defp do_stream(adapter_meta, {:cached, _, {_, cached}}, params, opts) do
    prepare_stream(adapter_meta, String.Chars.to_string(cached), params, opts)
  end

  defp do_stream(adapter_meta, {:nocache, {_id, prepared}}, params, opts) do
    prepare_stream(adapter_meta, prepared, params, opts)
  end

  defp prepare_stream(adapter_meta, prepared, params, opts) do
    adapter_meta
    |> Ecto.Adapters.SQL.Stream.build(prepared, params, opts)
    |> Stream.map(fn(%{num_rows: nrows, rows: rows}) -> {nrows, rows} end)
  end

  @doc false
  def reduce({pool, {loggers, sql, default_opts}}, statement, params, opts, acc, fun) do
    opts = with_log(loggers, params, opts ++ default_opts)

    case get_conn(pool) do
      nil  ->
        raise "cannot reduce stream outside of transaction"

      conn ->
        sql
        |> apply(:stream, [conn, statement, params, opts])
        |> Enumerable.reduce(acc, fun)
    end
  end

  @doc false
  def into({pool, {loggers, sql, default_opts}}, statement, params, opts) do
    opts = with_log(loggers, params, opts ++ default_opts)

    case get_conn(pool) do
      nil ->
        raise "cannot collect into stream outside of transaction"
      conn ->
        sql
        |> apply(:stream, [conn, statement, params, opts])
        |> Collectable.into()
    end
  end

  @doc false
  def struct(adapter_meta, conn, sql, info, values, on_conflict, returning, opts) do
    {operation, source, params} = info

    case query(adapter_meta, sql, values, opts) do
      {:ok, %{rows: nil, num_rows: 1}} ->
        {:ok, []}

      {:ok, %{rows: [values], num_rows: 1}} ->
        {:ok, Enum.zip(returning, values)}

      {:ok, %{num_rows: 0}} ->
        if on_conflict == :nothing, do: {:ok, []}, else: {:error, :stale}

      {:ok, %{num_rows: num_rows}} when num_rows > 1 ->
        raise Ecto.MultiplePrimaryKeyError,
              source: source, params: params, count: num_rows, operation: operation

      {:error, err} ->
        case conn.to_constraints(err) do
          [] -> raise err
          constraints -> {:invalid, constraints}
        end
    end
  end

  ## Transactions

  @doc false
  def transaction({pool, {loggers, _sql, default_opts}}, opts, fun) do
    opts = with_log(loggers, [], opts ++ default_opts)

    case get_conn(pool) do
      nil  -> do_transaction(pool, opts, fun)
      conn -> DBConnection.transaction(conn, fn(_) -> fun.() end, opts)
    end
  end

  defp do_transaction(pool, opts, fun) do
    run = fn conn ->
      try do
        put_conn(pool, conn)
        fun.()
      after
        delete_conn(pool)
      end
    end

    DBConnection.transaction(pool, run, opts)
  end

  @doc false
  def in_transaction?({pool, _}) do
    !!get_conn(pool)
  end

  @doc false
  def rollback({pool, _}, value) do
    case get_conn(pool) do
      nil  -> raise "cannot call rollback outside of transaction"
      conn -> DBConnection.rollback(conn, value)
    end
  end

  ## Migrations

  @doc false
  def execute_ddl(meta, sqls, opts) do
    for sql <- List.wrap(sqls) do
      query!(meta, sql, [], opts)
    end

    :ok
  end

  @doc false
  def lock_for_migrations(meta, query, opts, fun) do
    {_pool, {_loggers, _sql, default_opts}} = meta

    if Keyword.fetch(default_opts, :pool_size) == {:ok, 1} do
      raise_pool_size_error()
    end

    {:ok, result} =
      transaction(meta, opts ++ [log: false, timeout: :infinity], fn ->
        query
        |> Map.put(:lock, Keyword.get(default_opts, :migration_lock, "FOR UPDATE"))
        |> fun.()
      end)

    result
  end

  defp raise_pool_size_error do
    raise Ecto.MigrationError, """
    Migrations failed to run because the connection pool size is less than 2.

    Ecto requires a pool size of at least 2 to support concurrent migrators.
    When migrations run, Ecto uses one connection to maintain a lock and
    another to run migrations.

    If you are running migrations with Mix, you can increase the number
    of connections via the pool size option:

        mix ecto.migrate --pool-size 2

    If you are running the Ecto.Migrator programmatically, you can configure
    the pool size via your application config:

        config :my_app, Repo,
          ...,
          pool_size: 2 # at least
    """
  end

  ## Log

  defp with_log(loggers, params, opts) do
    case Keyword.pop(opts, :log, true) do
      {true, opts}  -> [log: &log(loggers, params, &1, opts)] ++ opts
      {false, opts} -> opts
    end
  end

  defp log(loggers, params, entry, opts) do
    %{
      connection_time: query_time,
      decode_time: decode_time,
      pool_time: queue_time,
      result: result,
      query: query
    } = entry

    source = Keyword.get(opts, :source)
    caller_pid = Keyword.get(opts, :caller, self())
    query_string = String.Chars.to_string(query)

    entry = %Ecto.LogEntry{
      query_time: query_time,
      decode_time: decode_time,
      queue_time: queue_time,
      result: log_result(result),
      params: params,
      query: query_string,
      ansi_color: sql_color(query_string),
      source: source,
      caller_pid: caller_pid
    }

    Ecto.LogEntry.apply(entry, loggers)
  end

  defp log_result({:ok, _query, res}), do: {:ok, res}
  defp log_result(other), do: other

  ## Connection helpers

  defp put_conn(pool, conn) do
    _ = Process.put(key(pool), conn)
    :ok
  end

  defp get_conn(pool) do
    Process.get(key(pool))
  end

  defp delete_conn(pool) do
    _ = Process.delete(key(pool))
    :ok
  end

  defp key(pool), do: {__MODULE__, pool}

  defp sql_color("SELECT" <> _), do: :cyan
  defp sql_color("ROLLBACK" <> _), do: :red
  defp sql_color("LOCK" <> _), do: :white
  defp sql_color("INSERT" <> _), do: :green
  defp sql_color("UPDATE" <> _), do: :yellow
  defp sql_color("DELETE" <> _), do: :red
  defp sql_color("begin" <> _), do: :magenta
  defp sql_color("commit" <> _), do: :magenta
  defp sql_color(_), do: nil
end
