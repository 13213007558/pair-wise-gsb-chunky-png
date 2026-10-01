# frozen_string_literal: true

require "spec_helper"

RSpec.describe "APNG chunks" do
  describe ChunkyPNG::Chunk::AnimationControl do
    it "serializes and parses the frame count and loop count" do
      chunk = ChunkyPNG::Chunk::AnimationControl.new(3, 0)
      parsed = serialized_chunk(chunk)
      expect(parsed).to be_a(ChunkyPNG::Chunk::AnimationControl)
      expect(parsed.num_frames).to eql(3)
      expect(parsed.num_plays).to eql(0)
    end

    it "rejects chunks that do not contain exactly 8 bytes" do
      expect {
        serialized_chunk(ChunkyPNG::Chunk::Generic.new("acTL", "x" * 7))
      }.to raise_error(ChunkyPNG::ExpectationFailed, /8 bytes/)
    end
  end

  describe ChunkyPNG::Chunk::FrameControl do
    it "serializes and parses all frame fields" do
      chunk = ChunkyPNG::Chunk::FrameControl.new(
        sequence_number: 5, width: 7, height: 11, x_offset: 1, y_offset: 2,
        delay_num: 3, delay_den: 4, dispose_op: 2, blend_op: 1
      )
      parsed = serialized_chunk(chunk)
      expect(parsed).to be_a(ChunkyPNG::Chunk::FrameControl)
      expect([parsed.sequence_number, parsed.width, parsed.height, parsed.x_offset, parsed.y_offset]).to eql([5, 7, 11, 1, 2])
      expect([parsed.delay_num, parsed.delay_den, parsed.dispose_op, parsed.blend_op]).to eql([3, 4, 2, 1])
      expect(parsed.delay).to eql(Rational(3, 4))
    end

    it "normalizes a zero delay denominator to 100 for the duration, without changing the chunk" do
      chunk = ChunkyPNG::Chunk::FrameControl.new(delay_num: 5, delay_den: 0)
      expect(chunk.delay).to eql(Rational(1, 20))
    end

    it "rejects chunks that do not contain exactly 26 bytes" do
      expect {
        serialized_chunk(ChunkyPNG::Chunk::Generic.new("fcTL", "x" * 25))
      }.to raise_error(ChunkyPNG::ExpectationFailed, /26 bytes/)
    end
  end


  describe ChunkyPNG::Chunk::FrameData do
    it "separates the sequence number from the deflated image data" do
      chunk = ChunkyPNG::Chunk::FrameData.new(9, "abc")
      parsed = serialized_chunk(chunk)
      expect(parsed).to be_a(ChunkyPNG::Chunk::FrameData)
      expect(parsed.sequence_number).to eql(9)
      expect(parsed.image_content).to eql("abc")
      expect(parsed.content).to eql([9].pack("N") << "abc")
    end

    it "rejects chunks without image data" do
      expect {
        serialized_chunk(ChunkyPNG::Chunk::Generic.new("fdAT", "x" * 3))
      }.to raise_error(ChunkyPNG::ExpectationFailed, /sequence number and image data/)
    end
  end
end
