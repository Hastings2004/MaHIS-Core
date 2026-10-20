# frozen_string_literal: true

# Certificates for site <-> central mutual TLS (design section 6: "fetching
# another site's patient requires the site certificate"). Client.rb already
# presents these if configured; central's HMAC check (base_controller.rb)
# already keeps working without them. Nginx terminates and verifies the TLS
# handshake in front of central -- see prototype/site_sync/docker/nginx-mtls/
# for a deployable config and README.md "Mutual TLS" for how to turn it on.
namespace :site_sync do
  namespace :tls do
    def cert_dir
      dir = ENV.fetch('SITE_SYNC_TLS_DIR', Rails.root.join('tmp/site_sync_tls').to_s)
      FileUtils.mkdir_p(dir)
      dir
    end

    desc 'Generate a self-signed CA for site <-> central mutual TLS (SITE_SYNC_TLS_DIR, default tmp/site_sync_tls)'
    task ca: :environment do
      key = OpenSSL::PKey::RSA.new(4096)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = OpenSSL::X509::Name.parse('/CN=MaHIS Site Sync CA')
      cert.issuer = cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = Time.now + (10 * 365 * 24 * 60 * 60)
      ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
      cert.add_extension(ef.create_extension('keyUsage', 'keyCertSign,cRLSign', true))
      cert.sign(key, OpenSSL::Digest.new('SHA256'))

      File.write(File.join(cert_dir, 'ca.key'), key.to_pem)
      File.write(File.join(cert_dir, 'ca.crt'), cert.to_pem)
      puts "CA written to #{cert_dir}/ca.{key,crt} (keep ca.key offline once sites are issued; nginx only needs ca.crt)"
    end

    desc "Issue a site's client certificate, signed by the CA: rake site_sync:tls:issue[KCH]"
    task :issue, [:site_code] => :environment do |_, args|
      site_code = args[:site_code] or abort 'usage: rake site_sync:tls:issue[SITE_CODE]'
      ca_key_path = File.join(cert_dir, 'ca.key')
      ca_crt_path = File.join(cert_dir, 'ca.crt')
      abort "No CA yet -- run `rake site_sync:tls:ca` first" unless File.exist?(ca_key_path)

      ca_key = OpenSSL::PKey::RSA.new(File.read(ca_key_path))
      ca_cert = OpenSSL::X509::Certificate.new(File.read(ca_crt_path))

      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = Time.now.to_i
      # CN is the site code: nginx forwards it as a trusted header after
      # verifying the chain, and base_controller.rb checks it matches
      # X-Site-Code, so a valid cert for one site cannot be replayed as another.
      cert.subject = OpenSSL::X509::Name.parse("/CN=#{site_code}")
      cert.issuer = ca_cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = Time.now + (2 * 365 * 24 * 60 * 60)
      ef = OpenSSL::X509::ExtensionFactory.new(ca_cert, cert)
      cert.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE'))
      cert.add_extension(ef.create_extension('keyUsage', 'digitalSignature,keyEncipherment'))
      cert.add_extension(ef.create_extension('extendedKeyUsage', 'clientAuth'))
      cert.sign(ca_key, OpenSSL::Digest.new('SHA256'))

      File.write(File.join(cert_dir, "#{site_code}.key"), key.to_pem)
      File.write(File.join(cert_dir, "#{site_code}.crt"), cert.to_pem)
      puts "#{site_code} cert written to #{cert_dir}/#{site_code}.{key,crt} (CN=#{site_code}, valid 2 years)"
    end
  end
end
