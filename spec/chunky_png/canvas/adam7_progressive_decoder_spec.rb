# frozen-string-literal: true

require "spec_helper"

describe ChunkyPNG::Canvas::Adam7ProgressiveDecoder do
  let(:canvas) { reference_canvas("adam7") }
  let(:datastream) { canvas.to_datastream(interlace: true, color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA, bit_depth: 8) }
  let(:idat) { datastream.data_chunks.map(&:content).join }

  def decoder_for(ds)
    ChunkyPNG::Canvas.progressive_adam7_decoder(ds)
  end

  it "creates independent snapshots with an accumulated valid pixel mask after each pass" do
    decoder = decoder_for(datastream)

    snapshots = idat.bytes.each_with_object([]) do |byte, result|
      result.concat(decoder.feed(byte.chr))
    end
    decoder.finish

    expect(snapshots.map(&:pass)).to eql (0..6).to_a
    expect(snapshots.map { |snapshot| snapshot.mask.count(true) }).to eql [1, 2, 4, 8, 16, 32, 64]
    expect(snapshots.last.canvas).to eql canvas
  end

  it "does not announce a pass until every scanline in that pass is available" do
    incomplete_positions = [
      [7, 0, 0, 0], [12, 1, 1, 1], [29, 3, 3, 4],
      [40, 4, 4, 8], [50, 5, 5, 16], [62, 6, 6, 32]
    ]

    incomplete_positions.each do |position, pass, snapshot_count, valid_pixels|
      incomplete_decoder = decoder_for(datastream)
      incomplete_decoder.feed(idat.byteslice(0, position))
      expect(incomplete_decoder.pass).to eql pass
      expect(incomplete_decoder.snapshots.length).to eql snapshot_count
      expect(incomplete_decoder.mask.count(true)).to eql valid_pixels
    end

    decoder = decoder_for(datastream)
    decoder.feed(idat.byteslice(0, 8))
    first_canvas = ChunkyPNG::Canvas.from_canvas(decoder.snapshots.first.canvas)

    decoder.feed(idat.byteslice(8, idat.bytesize - 8))
    decoder.finish

    expect(decoder.snapshots.first.canvas).to eql first_canvas
    expect(decoder.canvas).to eql canvas
  end

  it "supports arbitrary compressed IDAT byte boundaries" do
    (1...idat.bytesize).each do |chunk_size|
      decoder = decoder_for(datastream)
      position = 0
      while position < idat.bytesize
        decoder.feed(idat.byteslice(position, chunk_size))
        position += chunk_size
      end

      expect(decoder.finish.canvas).to eql canvas
    end
  end

  it "keeps an early snapshot unchanged after decoding continues" do
    decoder = decoder_for(datastream)
    decoder.feed(idat.byteslice(0, 8))
    first_snapshot = decoder.snapshots.first
    first_snapshot_pixels = first_snapshot.canvas.pixels.dup

    decoder.feed(idat.byteslice(8, idat.bytesize - 8))
    decoder.finish

    expect(first_snapshot.canvas.pixels).to eql first_snapshot_pixels
    expect(first_snapshot.mask.count(true)).to eql 1
    expect(decoder.canvas).to eql canvas
  end

  it "decodes IDAT payload split across multiple chunks" do
    multi_chunk_ds = ChunkyPNG::Datastream.from_blob(datastream.to_blob)
    content = multi_chunk_ds.data_chunks.first.content
    split = content.bytesize / 2
    multi_chunk_ds.data_chunks = [
      ChunkyPNG::Chunk::ImageData.new("IDAT", content.byteslice(0, split)),
      ChunkyPNG::Chunk::ImageData.new("IDAT", content.byteslice(split, content.bytesize - split))
    ]

    decoder = decoder_for(multi_chunk_ds)
    multi_chunk_ds.data_chunks.each { |data_chunk| decoder.feed(data_chunk.content) }

    expect(decoder.finish.canvas).to eql canvas
  end

  it "supports truecolor RGB images that require scanline decoding padding" do
    rgb_canvas = ChunkyPNG::Canvas.new(4, 4, canvas.pixels.first(16))
    rgb_ds = rgb_canvas.to_datastream(interlace: true, color_mode: ChunkyPNG::COLOR_TRUECOLOR, bit_depth: 8, compression: Zlib::BEST_SPEED, filtering: ChunkyPNG::FILTER_NONE)
    rgb_idat = rgb_ds.data_chunks.map(&:content).join
    decoder = decoder_for(rgb_ds)

    rgb_idat.each_byte { |byte| decoder.feed(byte.chr) }

    expect(decoder.finish.canvas).to eql rgb_canvas
  end

  it "advances through empty passes for small images" do
    ds = ChunkyPNG::Datastream.from_file(png_suite_file(:sizes, "s01i3p01.png"))
    decoder = decoder_for(ds)
    data = ds.data_chunks.map(&:content).join

    data.each_byte { |byte| decoder.feed(byte.chr) }
    final_snapshot = decoder.finish

    expect(decoder.snapshots.map(&:pass)).to eql (0..6).to_a
    expect(final_snapshot.mask.count(true)).to eql 1
    expect(final_snapshot.canvas).to eql ChunkyPNG::Image.from_file(png_suite_file(:sizes, "s01n3p01.png"))
  end

  it "decodes progressively through the high level blob entry" do
    saved_snapshots = []
    final_canvas = ChunkyPNG::Canvas.from_blob_progressive(datastream.to_blob, 3) do |snapshot|
      saved_snapshots << snapshot
    end

    expect(saved_snapshots.length).to eql 7
    expect(final_canvas).to eql canvas
    expect(saved_snapshots.last.canvas).to eql ChunkyPNG::Canvas.from_blob(datastream.to_blob)
  end

  it "returns the decoder when no snapshot block is provided" do
    decoder = ChunkyPNG::Canvas.from_blob_progressive(datastream.to_blob, 4)

    expect(decoder).to be_a(ChunkyPNG::Canvas::Adam7ProgressiveDecoder)
    expect(decoder.pass).to eql 7
    expect(decoder.canvas).to eql canvas
  end

  it "decodes progressively directly from an IO stream" do
    io = StringIO.new(datastream.to_blob, "rb")
    saved_snapshots = []
    result = ChunkyPNG::Canvas.from_io_progressive(io, 5) { |snapshot| saved_snapshots << snapshot }

    expect(result).to eql canvas
    expect(saved_snapshots.map(&:pass)).to eql (0..6).to_a
  end
end
