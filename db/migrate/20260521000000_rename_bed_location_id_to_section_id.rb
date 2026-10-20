class RenameBedLocationIdToSectionId < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:bed_mgmt_bed)

    remove_bed_location_foreign_key
    remove_bed_location_indexes

    if column_exists?(:bed_mgmt_bed, :location_id)
      if column_exists?(:bed_mgmt_bed, :section_id)
        # Both columns already exist (e.g. a skeleton restored from a database
        # that had this rename applied but kept the old column). Carry over
        # any value section_id is still missing before dropping location_id,
        # so a non-empty table never silently loses data.
        execute 'UPDATE bed_mgmt_bed SET section_id = location_id WHERE section_id IS NULL'
        remove_column :bed_mgmt_bed, :location_id
      else
        rename_column :bed_mgmt_bed, :location_id, :section_id
      end
    end

    add_bed_section_indexes
    add_bed_section_foreign_key
  end

  def down
    return unless table_exists?(:bed_mgmt_bed)

    remove_bed_section_foreign_key
    remove_bed_section_indexes

    rename_column :bed_mgmt_bed, :section_id, :location_id if column_exists?(:bed_mgmt_bed, :section_id)

    add_bed_location_indexes
    add_bed_location_foreign_key
  end

  private

  def remove_bed_location_foreign_key
    return unless foreign_key_exists?(:bed_mgmt_bed, :location, column: :location_id)

    remove_foreign_key :bed_mgmt_bed, column: :location_id
  end

  def remove_bed_location_indexes
    remove_index :bed_mgmt_bed, name: 'idx_bed_mgmt_bed_location_number' if index_exists?(
      :bed_mgmt_bed, %i[location_id bed_number], name: 'idx_bed_mgmt_bed_location_number'
    )
    remove_index :bed_mgmt_bed, name: 'idx_bed_mgmt_bed_location_status' if index_exists?(
      :bed_mgmt_bed, %i[location_id bed_status retired], name: 'idx_bed_mgmt_bed_location_status'
    )
  end

  def add_bed_section_indexes
    unless index_exists?(:bed_mgmt_bed, %i[section_id bed_number], name: 'idx_bed_mgmt_bed_section_number')
      add_index :bed_mgmt_bed, %i[section_id bed_number], unique: true, name: 'idx_bed_mgmt_bed_section_number'
    end
    unless index_exists?(:bed_mgmt_bed, %i[section_id bed_status retired], name: 'idx_bed_mgmt_bed_section_status')
      add_index :bed_mgmt_bed, %i[section_id bed_status retired], name: 'idx_bed_mgmt_bed_section_status'
    end
  end

  def add_bed_section_foreign_key
    return if foreign_key_exists?(:bed_mgmt_bed, :location, column: :section_id)

    add_foreign_key :bed_mgmt_bed, :location, column: :section_id, primary_key: :location_id
  end

  def remove_bed_section_foreign_key
    return unless foreign_key_exists?(:bed_mgmt_bed, :location, column: :section_id)

    remove_foreign_key :bed_mgmt_bed, column: :section_id
  end

  def remove_bed_section_indexes
    remove_index :bed_mgmt_bed, name: 'idx_bed_mgmt_bed_section_number' if index_exists?(
      :bed_mgmt_bed, %i[section_id bed_number], name: 'idx_bed_mgmt_bed_section_number'
    )
    remove_index :bed_mgmt_bed, name: 'idx_bed_mgmt_bed_section_status' if index_exists?(
      :bed_mgmt_bed, %i[section_id bed_status retired], name: 'idx_bed_mgmt_bed_section_status'
    )
  end

  def add_bed_location_indexes
    unless index_exists?(:bed_mgmt_bed, %i[location_id bed_number], name: 'idx_bed_mgmt_bed_location_number')
      add_index :bed_mgmt_bed, %i[location_id bed_number], unique: true, name: 'idx_bed_mgmt_bed_location_number'
    end
    unless index_exists?(:bed_mgmt_bed, %i[location_id bed_status retired], name: 'idx_bed_mgmt_bed_location_status')
      add_index :bed_mgmt_bed, %i[location_id bed_status retired], name: 'idx_bed_mgmt_bed_location_status'
    end
  end

  def add_bed_location_foreign_key
    return if foreign_key_exists?(:bed_mgmt_bed, :location, column: :location_id)

    add_foreign_key :bed_mgmt_bed, :location, column: :location_id, primary_key: :location_id
  end
end
