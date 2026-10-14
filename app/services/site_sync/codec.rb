# frozen_string_literal: true

module SiteSync
  # Translates between a node's local integer ids and uuids.
  #
  # On the wire a row travels with its own column values (local ids included,
  # so central's backup copy is exact) plus a `refs` map giving, for every
  # foreign key, the uuid of the row it points at. The receiving node uses
  # `refs` to find its own ids for those rows.
  class Codec
    class MissingRef < StandardError
      attr_reader :table, :uuid, :column

      def initialize(table, uuid, column)
        @table = table
        @uuid = uuid
        @column = column
        super("#{column} points at #{table} #{uuid}, which is not here")
      end
    end

    def initialize(connection = ActiveRecord::Base.lease_connection)
      @connection = connection
      @uuid_cache = {}
      @id_cache = {}
    end

    # uuid of local row `id` in `table` (a synced table or users).
    def uuid_for(table, id)
      return nil if id.nil?

      @uuid_cache[[table, id]] ||= begin
        via = table == 'users' ? nil : Config.uuid_via(table)
        source = via || table
        key = table == 'users' ? 'user_id' : Config.pk(via || table)
        @connection.select_value("SELECT `uuid` FROM `#{source}` WHERE `#{key}` = #{@connection.quote(id)}")
      end
    end

    # Local id of the row with `uuid` in `table`, or nil.
    def id_for(table, uuid)
      return nil if uuid.nil?

      @id_cache[[table, uuid]] ||=
        if table == 'users'
          @connection.select_value("SELECT user_id FROM users WHERE uuid = #{@connection.quote(uuid)}")
        elsif (via = Config.uuid_via(table))
          @connection.select_value(<<~SQL)
            SELECT t.`#{Config.pk(table)}` FROM `#{table}` t
            JOIN `#{via}` v ON v.`#{Config.pk(via)}` = t.`#{Config.pk(table)}`
            WHERE v.`uuid` = #{@connection.quote(uuid)}
          SQL
        else
          @connection.select_value(
            "SELECT `#{Config.pk(table)}` FROM `#{table}` WHERE `uuid` = #{@connection.quote(uuid)}"
          )
        end
    end

    def forget(table, uuid)
      @id_cache.delete([table, uuid])
    end

    # { column => uuid } for every foreign key in `row` that is translated by uuid.
    def encode_refs(table, row)
      refs = {}
      Config.refs(table).each { |col, target| refs[col] = uuid_for(target, row[col]) }
      Config.reference_refs.each do |col, spec|
        next unless row.key?(col) && spec['match'] == 'uuid'

        refs[col] = uuid_for(spec['table'], row[col])
      end
      refs
    end

    # The row's values with foreign keys replaced by this node's ids. The
    # primary key is dropped (this node assigns its own) unless it is itself a
    # reference (patient.patient_id is the person's id).
    def localize(table, row, refs)
      local = row.dup
      local.delete(Config.pk(table)) unless Config.refs(table).key?(Config.pk(table))

      # Only the columns the event carries (an update may carry a few).
      Config.refs(table).each do |col, target|
        next unless row.key?(col)

        local[col] = resolve(target, refs[col], col, row[col])
      end
      Config.reference_refs.each do |col, spec|
        next unless local.key?(col) && spec['match'] == 'uuid'

        local[col] = resolve(spec['table'], refs[col], col, row[col])
      end
      # Ids into tables outside sync mean nothing on another node: leave the
      # column out, so an update keeps the receiver's own value and an insert
      # gets the column default.
      Config.unsynced_refs.each { |col| local.delete(col) }
      local
    end

    # Uuid of the patient a row belongs to (for subscription filtering).
    def self.patient_uuid(table, uuid, refs)
      ref = Config.patient_ref(table)
      ref == 'self' ? uuid : refs[ref]
    end

    private

    def resolve(target, uuid, col, original)
      return nil if original.nil? && uuid.nil?
      raise MissingRef.new(target, uuid, col) if uuid.nil?

      id_for(target, uuid) || raise(MissingRef.new(target, uuid, col))
    end
  end
end
