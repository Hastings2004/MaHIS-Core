# frozen_string_literal: true

module SiteSync
  # SQL fragments shared by the capture triggers, the reconciler and the
  # restore check. Row hashes are only ever computed by MySQL from these same
  # expressions, so a row hashes identically wherever it is hashed (Ruby and
  # MySQL format datetimes and doubles differently).
  module RowSql
    module_function

    # JSON_OBJECT('col', <prefix>`col`, ...) over every column of the table.
    # prefix is "NEW.", "OLD." or a table alias such as "t.".
    def json(table, prefix)
      pairs = Config.columns(table).map { |col| "'#{col}', #{prefix}`#{col}`" }
      "JSON_OBJECT(#{pairs.join(', ')})"
    end

    def hash_expr(table, prefix)
      "SHA2(CAST(#{json(table, prefix)} AS CHAR), 256)"
    end

    # Expression giving the row's uuid. patient borrows the person's uuid.
    def uuid(table, prefix)
      via = Config.uuid_via(table)
      return "#{prefix}`uuid`" unless via

      "(SELECT `uuid` FROM `#{via}` WHERE `#{Config.pk(via)}` = #{prefix}`#{Config.pk(table)}`)"
    end

    # SELECT list giving (uuid, local id, row hash) for every row of a table.
    # Used by reconciliation and the post-restore check.
    def hashed_rows(table)
      if (via = Config.uuid_via(table))
        <<~SQL
          SELECT v.`uuid` AS row_uuid, t.`#{Config.pk(table)}` AS local_id, #{hash_expr(table, 't.')} AS row_hash
          FROM `#{table}` t JOIN `#{via}` v ON v.`#{Config.pk(via)}` = t.`#{Config.pk(table)}`
        SQL
      else
        <<~SQL
          SELECT t.`uuid` AS row_uuid, t.`#{Config.pk(table)}` AS local_id, #{hash_expr(table, 't.')} AS row_hash
          FROM `#{table}` t
        SQL
      end
    end
  end
end
