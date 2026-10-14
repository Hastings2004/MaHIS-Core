# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/site_sync/merkle'

RSpec.describe SiteSync::Merkle do
  describe '.differing' do
    it 'lists buckets whose digests differ, including buckets only one side has' do
      ours = { '0a' => '3:100', '0b' => '1:7', '0c' => '2:9' }
      theirs = { '0a' => '3:100', '0b' => '1:8', '0d' => '1:1' }
      expect(described_class.differing(ours, theirs)).to eq(%w[0b 0c 0d])
    end

    it 'finds nothing when both sides agree' do
      digests = { '0a' => '3:100' }
      expect(described_class.differing(digests, digests.dup)).to be_empty
    end
  end

  describe '.table_digest' do
    it 'adds bucket counts and sums, so the order rows were read in does not matter' do
      expect(described_class.table_digest({ 'aa' => '2:10', 'bb' => '3:5' })).to eq('5:15')
      expect(described_class.table_digest({ 'bb' => '3:5', 'aa' => '2:10' })).to eq('5:15')
    end
  end
end
