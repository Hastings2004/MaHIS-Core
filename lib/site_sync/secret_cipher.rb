# frozen_string_literal: true

module SiteSync
  # Encrypts sync_sites.secret at rest. Reversible (not hashed): the secret
  # signs HMAC requests, so central needs the raw value back to verify them,
  # not just a comparable digest.
  module SecretCipher
    module_function

    def cipher
      @cipher ||= begin
        key = ActiveSupport::KeyGenerator.new(Config.secret_cipher_key)
                                          .generate_key('site_sync/sync_sites_secret', ActiveSupport::MessageEncryptor.key_len)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end

    def encrypt(plaintext)
      cipher.encrypt_and_sign(plaintext)
    end

    def decrypt(ciphertext)
      cipher.decrypt_and_verify(ciphertext)
    end
  end
end
