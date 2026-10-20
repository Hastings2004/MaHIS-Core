# frozen_string_literal: true

module SiteSync
  # Central-only: when a brand-new patient arrives from a site, looks for an
  # existing person who might be the same real-world patient (design section
  # 5: "matched centrally by national ID, then name, sex, birth date").
  #
  # Deliberately never merges automatically. A strong match (same national
  # ID) and a weaker match (same name/sex/birthdate) are both just recorded
  # as open candidates for a data officer -- merging clinical history across
  # sites is a "central decision" of its own, not something to guess at here.
  class DuplicateDetector
    def initialize(connection = ActiveRecord::Base.lease_connection)
      @conn = connection
    end

    def check(uuid)
      person = @conn.select_one("SELECT * FROM person WHERE uuid = #{q(uuid)} AND voided = 0")
      return unless person

      national_id = national_id_for(person['person_id'])
      if national_id
        find_by_national_id(national_id, person['person_id']).each do |match|
          record_candidate(uuid, match['uuid'], 'national_id', national_id)
        end
        return
      end

      find_by_name_sex_birthdate(person).each do |match|
        record_candidate(uuid, match['uuid'], 'name_sex_birthdate', nil)
      end
    end

    private

    def national_id_for(person_id)
      @conn.select_value(<<~SQL)
        SELECT i.identifier FROM patient_identifier i
        JOIN patient_identifier_type t ON t.patient_identifier_type_id = i.identifier_type
        WHERE i.patient_id = #{person_id.to_i} AND i.voided = 0 AND t.name = #{q(Config.national_id_identifier_type_name)}
        LIMIT 1
      SQL
    end

    def find_by_national_id(national_id, exclude_person_id)
      @conn.select_all(<<~SQL).to_a
        SELECT DISTINCT p.person_id, p.uuid FROM patient_identifier i
        JOIN patient_identifier_type t ON t.patient_identifier_type_id = i.identifier_type
        JOIN person p ON p.person_id = i.patient_id AND p.voided = 0
        WHERE i.identifier = #{q(national_id)} AND i.voided = 0 AND t.name = #{q(Config.national_id_identifier_type_name)}
          AND p.person_id <> #{exclude_person_id.to_i}
      SQL
    end

    def find_by_name_sex_birthdate(person)
      return [] unless person['gender'].present? && person['birthdate'].present?

      name = @conn.select_one(<<~SQL)
        SELECT given_name, family_name FROM person_name
        WHERE person_id = #{person['person_id'].to_i} AND voided = 0 LIMIT 1
      SQL
      return [] unless name && name['given_name'].present? && name['family_name'].present?

      @conn.select_all(<<~SQL).to_a
        SELECT DISTINCT p.person_id, p.uuid FROM person p
        JOIN person_name n ON n.person_id = p.person_id AND n.voided = 0
        WHERE LOWER(n.given_name) = #{q(name['given_name'].downcase)}
          AND LOWER(n.family_name) = #{q(name['family_name'].downcase)}
          AND p.gender = #{q(person['gender'])} AND p.birthdate = #{q(person['birthdate'])}
          AND p.person_id <> #{person['person_id'].to_i} AND p.voided = 0
      SQL
    end

    def record_candidate(new_uuid, matched_uuid, strength, national_id)
      already = @conn.select_value(<<~SQL)
        SELECT 1 FROM sync_duplicate_candidates
        WHERE new_uuid = #{q(new_uuid)} AND matched_uuid = #{q(matched_uuid)}
      SQL
      return if already

      @conn.execute(<<~SQL)
        INSERT INTO sync_duplicate_candidates (new_uuid, matched_uuid, match_strength, national_id, status, created_at)
        VALUES (#{q(new_uuid)}, #{q(matched_uuid)}, #{q(strength)}, #{q(national_id)}, 'open', NOW(6))
      SQL
      Central.alert(nil, 'possible_duplicate_patient',
                    "New patient #{new_uuid} may be the same as #{matched_uuid} (#{strength})")
    end

    def q(value)
      @conn.quote(value)
    end
  end
end
