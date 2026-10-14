# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/site_sync/hlc'

RSpec.describe SiteSync::Hlc do
  describe '.tick' do
    it 'follows the wall clock when it moves forward' do
      expect(described_class.tick(1_000, 5_000)).to eq(5_000)
    end

    it 'never goes backwards when the clock is set back (e.g. after a power cut)' do
      expect(described_class.tick(5_000, 1_000)).to eq(5_001)
    end

    it 'still increases when two changes share the same microsecond' do
      expect(described_class.tick(5_000, 5_000)).to eq(5_001)
    end
  end

  describe '.receive' do
    it 'stays ahead of every clock value seen from another node' do
      expect(described_class.receive(100, 9_000, 50)).to eq(9_000)
      expect(described_class.receive(9_000, 100, 50)).to eq(9_001)
    end
  end

  it 'round-trips through Time at microsecond precision' do
    time = Time.at(1_791_972_383, 181_920, :usec)
    expect(described_class.to_time(described_class.from_time(time))).to eq(time)
  end
end
