# frozen_string_literal: true

# The weight/height reference tables exist in MaHIS but nothing populated them,
# so /patients/:id/median_weight_height returned null values and
# /patient_weight_for_height_values returned an empty object. Clients compute
# "percent of median" vitals for children from these values and ended up
# posting NaN.
#
# The same files in db/data are imported by db:seed on fresh installations;
# this migration covers databases that already exist. A table that already has
# rows is left alone.
class LoadWeightHeightReferenceData < ActiveRecord::Migration[8.1]
  REFERENCE_TABLES = %w[weight_height_for_ages weight_for_heights].freeze

  def up
    REFERENCE_TABLES.each do |table|
      unless table_exists?(table)
        say "#{table} does not exist, skipping"
        next
      end

      if select_value("SELECT COUNT(*) FROM #{table}").to_i.positive?
        say "#{table} already has data, skipping"
        next
      end

      File.read(Rails.root.join('db', 'data', "#{table}.sql")).split(/;\s*$/).each do |statement|
        statement = statement.lines.reject { |line| line.start_with?('--') }.join.strip
        execute(statement) unless statement.empty?
      end
      say "#{table}: #{select_value("SELECT COUNT(*) FROM #{table}")} rows loaded"
    end
  end

  def down
    # Reference data only; nothing to undo.
  end
end
