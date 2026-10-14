# frozen_string_literal: true

module SiteSync
  # Raw-SQL reads and writes on synced tables. Sync never goes through the
  # ActiveRecord models: model callbacks (MNH stats refreshes, location
  # stamping, default scopes) must not fire once per replicated row.
  class RowStore
    def initialize(connection = ActiveRecord::Base.lease_connection)
      @connection = connection
    end

    # The row as a Hash, in the same JSON form the capture triggers produce.
    def current(table, id)
      json = @connection.select_value(
        "SELECT #{RowSql.json(table, 't.')} FROM `#{table}` t WHERE t.`#{Config.pk(table)}` = #{q(id)}"
      )
      json && JSON.parse(json)
    end

    def current_hash(table, id)
      @connection.select_value(
        "SELECT #{RowSql.hash_expr(table, 't.')} FROM `#{table}` t WHERE t.`#{Config.pk(table)}` = #{q(id)}"
      )
    end

    def insert(table, values)
      cols = values.keys
      @connection.execute(
        "INSERT INTO `#{table}` (#{cols.map { |c| "`#{c}`" }.join(', ')}) " \
        "VALUES (#{cols.map { |c| q(values[c]) }.join(', ')})"
      )
      values[Config.pk(table)] || @connection.select_value('SELECT LAST_INSERT_ID()')
    end

    def update(table, id, values)
      return if values.empty?

      sets = values.map { |col, value| "`#{col}` = #{q(value)}" }.join(', ')
      @connection.execute("UPDATE `#{table}` SET #{sets} WHERE `#{Config.pk(table)}` = #{q(id)}")
    end

    def delete(table, id)
      @connection.execute("DELETE FROM `#{table}` WHERE `#{Config.pk(table)}` = #{q(id)}")
    end

    # Write a row exactly as given, original ids included (restore and repair).
    def put_exact(table, values)
      cols = values.keys
      updates = cols.reject { |c| c == Config.pk(table) }.map { |c| "`#{c}` = VALUES(`#{c}`)" }
      @connection.execute(
        "INSERT INTO `#{table}` (#{cols.map { |c| "`#{c}`" }.join(', ')}) " \
        "VALUES (#{cols.map { |c| q(values[c]) }.join(', ')}) " \
        "ON DUPLICATE KEY UPDATE #{updates.join(', ')}"
      )
    end

    private

    def q(value)
      @connection.quote(value)
    end
  end
end
