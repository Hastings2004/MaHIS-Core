# frozen_string_literal: true

# Small toolkit for the demo scenes: talk to the three databases directly
# (to show and check results), call the sites' real MaHIS API (to make
# changes the way a clinician would), control the simulated links, and run
# rake tasks on a node.
require 'json'
require 'net/http'
require 'securerandom'
require 'shellwords'
require 'mysql2'

module Demo
  ROOT = File.expand_path('../../..', __dir__)
  PROTO = File.expand_path('..', __dir__)
  DATABASES = { central: 'mahis_central', a: 'mahis_site_a', b: 'mahis_site_b' }.freeze
  API_PORTS = { a: 3201, b: 3202, central: 3200 }.freeze
  ADMIN_TOKEN = 'demo-admin-token'
  API_TOKEN = 'demo-token'
  OPD_PROGRAM = 14
  VITALS = 6
  WEIGHT = 53_325

  class Failure < StandardError; end

  module_function

  # ---- output -------------------------------------------------------------

  def title(text)
    puts "\n#{'=' * 78}\n#{text}\n#{'=' * 78}"
  end

  def step(text)
    puts "\n▶ #{text}"
  end

  def info(text)
    puts "    #{text}"
  end

  def results
    @results ||= []
  end

  def check(description)
    ok = yield
    results << [description, ok]
    puts "    #{ok ? 'PASS' : 'FAIL'}  #{description}"
    ok
  rescue StandardError => e
    results << [description, false]
    puts "    FAIL  #{description} (#{e.class}: #{e.message})"
    false
  end

  def measure(name, value)
    (@measurements ||= {})[name] = value
    puts "    ⏱  #{name}: #{value}"
  end

  def measurements
    @measurements || {}
  end

  # ---- databases ----------------------------------------------------------

  def db(node)
    @db ||= {}
    @db[node] ||= Mysql2::Client.new(host: '127.0.0.1', port: 3307, username: 'proto', password: 'proto',
                                     database: DATABASES.fetch(node))
  end

  def rows(node, sql)
    db(node).query(sql).to_a
  end

  def value(node, sql)
    rows(node, sql).first&.values&.first
  end

  def esc(text)
    db(:central).escape(text.to_s)
  end

  def person_uuid(node, person_id)
    value(node, "SELECT uuid FROM person WHERE person_id = #{person_id.to_i}")
  end

  def person_id(node, uuid)
    value(node, "SELECT person_id FROM person WHERE uuid = '#{esc(uuid)}'")
  end

  def at_central?(table, uuid)
    via = table == 'patient' ? 'person' : table
    !value(:central, "SELECT 1 FROM `#{via}` WHERE uuid = '#{esc(uuid)}'").nil?
  end

  # ---- waiting ------------------------------------------------------------

  def wait_for(description, timeout: 60, interval: 0.5)
    started = Time.now
    loop do
      return (Time.now - started).round(1) if yield
      raise Failure, "timed out after #{timeout}s waiting for: #{description}" if Time.now - started > timeout

      sleep interval
    end
  end

  # ---- MaHIS API on a site -------------------------------------------------

  def api(site, method, path, body = nil)
    http = Net::HTTP.new('127.0.0.1', API_PORTS.fetch(site))
    http.read_timeout = 60
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method)
    request = klass.new(path)
    request['Authorization'] = API_TOKEN
    request['Content-Type'] = 'application/json'
    request.body = body.to_json if body
    response = http.request(request)
    parsed = response.body.to_s.empty? ? {} : (JSON.parse(response.body) rescue { 'raw' => response.body[0, 300] })
    [response.code.to_i, parsed, response['X-Request-Id']]
  end

  # Registers a patient the way the registration screen does: person, then patient.
  def register_patient(site, given:, family:, gender: 'F', birthdate: '1990-05-17')
    status, person, request_id = api(site, :post, '/api/v1/people', {
                                       given_name: given, family_name: family, gender:, birthdate:,
                                       birthdate_estimated: false, current_district: 'Lilongwe',
                                       current_traditional_authority: 'Kalumbu', current_village: 'Area 25',
                                       home_district: 'Lilongwe', home_traditional_authority: 'Kalumbu',
                                       home_village: 'Area 25', country: 'Malawi'
                                     })
    raise Failure, "POST /api/v1/people -> #{status}: #{person.to_s[0, 300]}" unless status == 201

    status, patient, = api(site, :post, '/api/v1/patients', { person_id: person['person_id'], program_id: OPD_PROGRAM })
    raise Failure, "POST /api/v1/patients -> #{status}: #{patient.to_s[0, 300]}" unless status == 201

    { person_id: person['person_id'], uuid: person_uuid(site, person['person_id']), request_id: }
  end

  def record_weight(site, patient_id, kg)
    status, encounter, request_id = api(site, :post, '/api/v1/encounters', {
                                          encounter_type_id: VITALS, patient_id:, program_id: OPD_PROGRAM,
                                          obs: [{ concept_id: WEIGHT, value_numeric: kg }]
                                        })
    raise Failure, "POST /api/v1/encounters -> #{status}: #{encounter.to_s[0, 300]}" unless status == 201

    { encounter_id: encounter['encounter_id'], uuid: encounter['uuid'], request_id: }
  end

  # ---- central admin API ----------------------------------------------------

  def admin(method, path)
    http = Net::HTTP.new('127.0.0.1', API_PORTS[:central])
    request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(path)
    request['X-Admin-Token'] = ADMIN_TOKEN
    response = http.request(request)
    JSON.parse(response.body)
  end

  # ---- processes ------------------------------------------------------------

  def sh(command, node: nil, quiet: false)
    env = node ? "source #{PROTO}/env.sh #{node} >/dev/null && " : ''
    output = `cd #{ROOT} && bash -c #{Shellwords.escape("#{env}#{command}")} 2>&1`
    output = output.lines.reject { |l| l.include?('MultiJson') || l =~ /^\s+from / }.join
    puts output.lines.map { |l| "    | #{l}" }.join unless quiet || output.strip.empty?
    raise Failure, "command failed: #{command}" unless $?.success?

    output
  end

  def link(site, *args)
    sh("#{PROTO}/bin/link #{site} #{args.join(' ')}")
  end

  def unsent(node)
    value(node, <<~SQL).to_i
      SELECT COUNT(*) FROM sync_change_log l LEFT JOIN sync_batches b ON b.id = l.batch_id
      WHERE l.batch_id IS NULL OR b.status <> 'acked'
    SQL
  end
end
