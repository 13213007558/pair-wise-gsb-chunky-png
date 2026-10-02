# frozen_string_literal: true

module ChunkyPNG
  # Builds one indexed palette for multiple images.
  module Quantizer
    extend self

    DEFAULT_PALETTE_SIZE = 64
    MAX_PALETTE_SIZE = 256
    MAX_ITERATIONS = 32

    # Quantizes a collection of images to one shared palette.
    #
    # @param images [Enumerable] Canvases or arrays of RGBA pixel values.
    # @param options [Hash] The quantization options.
    # @option options [Integer] :size The palette size (default 64).
    # @option options [Array<Numeric>, Numeric] :weights Per-image weights.
    # @option options [Array<Integer>, Hash] :fixed_colors Colors that must
    #   keep their palette position. Arrays reserve positions from 0 upward.
    # @option options [Integer] :transparent_index Position of the transparent
    #   palette entry (default: immediately after fixed colors).
    # @option options [Integer] :transparent_color The fully transparent color.
    # @return [Array(ChunkyPNG::Palette, Array<Array<Integer>>)] The shared
    #   palette and one array of palette indexes for every input image.
    def quantize(images, options = {})
      images = Array(images)
      raise ArgumentError, "At least one image is required" if images.empty?

      palette_size = extract_palette_size(options)
      weights = extract_weights(images, options)
      pixel_data = images.map { |image| pixels_from(image) }
      reserved = extract_reserved_colors(options, palette_size)

      histogram = build_histogram(pixel_data, weights, reserved)
      fitting_colors = reserved.reject { |entry| Color.fully_transparent?(entry[1]) }
      generated = generated_colors(histogram, fitting_colors.map(&:last), reserved.size, palette_size)
      palette_colors = compose_palette(generated, reserved, palette_size)
      validate_capacity!(histogram, palette_colors, reserved)
      fixed_indexes = fixed_indexes(reserved)
      active_indexes = active_palette_indexes(palette_colors, reserved)
      indexed_images = map_images(pixel_data, palette_colors, fixed_indexes, active_indexes, reserved.transparent_index)

      [Palette.from_ordered_colors(palette_colors), indexed_images]
    end
    alias quantize_images quantize
    alias quantize_pixels quantize

    private

    def extract_palette_size(options)
      size = options[:size] || options[:palette_size] || options[:colors] || DEFAULT_PALETTE_SIZE
      unless size.is_a?(Integer) && (1..MAX_PALETTE_SIZE).cover?(size)
        raise ArgumentError, "Palette size must be an integer between 1 and #{MAX_PALETTE_SIZE}"
      end

      size
    end

    def extract_weights(images, options)
      weights = options.fetch(:weights, 1)
      weights = Array(weights)
      weights = Array.new(images.length, weights.first) if weights.length == 1

      unless weights.length == images.length && weights.all? { |weight| weight.is_a?(Numeric) && weight > 0 }
        raise ArgumentError, "Weights must be positive and match the number of images"
      end

      weights
    end

    def extract_reserved_colors(options, palette_size)
      fixed = options.fetch(:fixed_colors) { options.fetch(:brand_colors) { options.fetch(:fixed_palette, []) } }
      entries = fixed_entries(fixed)
      transparent_index, transparent_color = transparent_options(options, entries)
      unless transparent_index.nil?
        entries << [transparent_index, transparent_color] unless entries.any? { |index, _| index == transparent_index }
      end

      validate_reserved!(entries, palette_size, transparent_index)
      ReservedPalette.new(entries, transparent_index)
    end

    def fixed_entries(fixed)
      case fixed
      when Hash
        fixed.map { |index, color| [Integer(index), Color.parse(color)] }
      else
        Array(fixed).each_with_index.map { |color, index| [index, Color.parse(color)] }
      end
    end

    def transparent_options(options, reserved_entries)
      fixed_transparent = reserved_entries.find { |_, color| Color.fully_transparent?(color) }
      color = if options.key?(:transparent_color)
        options[:transparent_color]
      else
        fixed_transparent ? fixed_transparent.last : Color::TRANSPARENT
      end
      if !color.nil? && !Color.fully_transparent?(Color.parse(color))
        raise ArgumentError, "The transparent palette color must be fully transparent"
      end
      color = Color.parse(color) unless color.nil?

      index = if options.key?(:transparent_index)
        options[:transparent_index]
      elsif options.key?(:transparent_slot)
        options[:transparent_slot]
      elsif fixed_transparent
        fixed_transparent.first
      elsif color.nil?
        nil
      else
        reserved_entries.length
      end

      [index.nil? ? nil : Integer(index), color]
    end

    def validate_reserved!(entries, palette_size, transparent_index)
      positions = entries.map(&:first)
      colors = entries.map(&:last)

      unless positions.all? { |position| (0...palette_size).cover?(position) }
        raise ArgumentError, "Reserved palette positions must be within the palette"
      end
      raise ArgumentError, "Reserved palette positions must be unique" unless positions.uniq.length == positions.length
      raise ArgumentError, "Reserved palette colors must be unique" unless colors.uniq.length == colors.length

      unless transparent_index.nil?
        transparent_entry = entries.find { |index, _| index == transparent_index }
        if transparent_entry.nil? || !Color.fully_transparent?(transparent_entry.last)
          raise ArgumentError, "The transparent palette slot must contain a fully transparent color"
        end
      end
    end

    def pixels_from(image)
      pixels = image.respond_to?(:pixels) ? image.pixels : image
      unless pixels.is_a?(Enumerable)
        raise ArgumentError, "Images must be canvases or enumerables of pixel values"
      end

      pixels.to_a
    end

    def build_histogram(images, weights, reserved)
      histogram = Hash.new(0)
      reserved_colors = reserved.colors

      images.each_with_index do |pixels, image_index|
        pixels.each do |pixel|
          color = Color.parse(pixel)
          next if Color.fully_transparent?(color) || reserved_colors.include?(color)

          histogram[color] += weights[image_index]
        end
      end

      histogram
    end

    def generated_colors(histogram, fixed_centroids, reserved_count, palette_size)
      target = [palette_size - reserved_count, histogram.length].min
      return [] if target <= 0

      generated = initial_centroids(histogram, fixed_centroids, target)
      centroids = fixed_centroids + generated

      MAX_ITERATIONS.times do
        clusters = Array.new(centroids.length) { [] }
        histogram.each do |color, weight|
          clusters[nearest_centroid(color, centroids)] << [color, weight]
        end

        moved = false
        generated.length.times do |generated_index|
          centroid_index = fixed_centroids.length + generated_index
          next_centroid = weighted_centroid(clusters[centroid_index])
          if next_centroid.nil? || duplicate_centroid?(centroids, centroid_index, next_centroid)
            next_centroid = reseed_centroid(histogram, centroids, centroid_index)
          end
          moved ||= next_centroid != centroids[centroid_index]
          centroids[centroid_index] = next_centroid
        end

        generated = centroids[fixed_centroids.length..-1]
        break unless moved
      end

      generated.uniq.reject { |color| fixed_centroids.include?(color) }.sort
    end

    def initial_centroids(histogram, fixed_centroids, target)
      candidates = histogram.keys.sort
      generated = []

      until generated.length == target || candidates.empty?
        selected = candidates.max_by do |color|
          centroids = fixed_centroids + generated
          distance = centroids.empty? ? 0 : centroids.map { |centroid| squared_distance(color, centroid) }.min
          [histogram[color] * distance, color]
        end

        generated << selected
        candidates.delete(selected)
      end

      generated
    end

    def nearest_centroid(color, centroids)
      centroids.each_with_index.min_by { |centroid, index| [squared_distance(color, centroid), index] }.last
    end

    def weighted_centroid(cluster)
      return nil if cluster.empty?

      total_weight = cluster.map(&:last).inject(0, :+).to_f
      components = [0, 0, 0, 0].map.with_index do |_, channel|
        weighted_sum = cluster.map { |color, weight| component(color, channel) * weight }.inject(0, :+).to_f
        (weighted_sum / total_weight).round
      end

      Color.rgba(*components)
    end

    def duplicate_centroid?(centroids, centroid_index, candidate)
      centroids.each_with_index.any? { |centroid, index| index != centroid_index && centroid == candidate }
    end

    def reseed_centroid(histogram, centroids, centroid_index)
      available = histogram.keys.reject { |color| centroids.include?(color) }.sort
      available.max_by do |color|
        other_centroids = centroids.each_with_index.reject { |_, index| index == centroid_index }.map(&:first)
        distance = other_centroids.map { |centroid| squared_distance(color, centroid) }.min || 0
        [histogram[color] * distance, color]
      end || fill_color_not_in(centroids)
    end

    def compose_palette(generated, reserved, palette_size)
      colors = Array.new(palette_size)
      reserved.entries.each { |index, color| colors[index] = color }

      free_indexes = colors.each_index.select { |index| colors[index].nil? }
      generated.each do |color|
        index = free_indexes.shift
        break if index.nil?
        colors[index] = color
      end

      fill_palette(colors)
    end

    def validate_capacity!(histogram, palette_colors, reserved)
      visible_active_slots = palette_colors.each_with_index.any? do |color, index|
        index != reserved.transparent_index && !Color.fully_transparent?(color)
      end

      if histogram.any? && !visible_active_slots
        raise ArgumentError, "Palette is too small to represent transparent and opaque colors"
      end
    end

    def fill_palette(colors)
      colors.each_index do |index|
        next unless colors[index].nil?

        colors[index] = fill_color_not_in(colors)
      end
      colors
    end

    def fill_color_not_in(colors)
      fill_colors.find { |color| !colors.include?(color) }
    end

    def fill_colors
      @fill_colors ||= (0..Color::MAX).map { |value| Color.grayscale(value) } +
        (0...(Color::MAX + 1)**3).map do |value|
          Color.rgb(value >> 16, (value >> 8) & Color::MAX, value & Color::MAX)
        end
    end

    def active_palette_indexes(palette_colors, reserved)
      active = {}
      palette_colors.each_with_index do |color, index|
        next if index == reserved.transparent_index
        next if Color.fully_transparent?(color)

        active[color] ||= index
      end
      active
    end

    def fixed_indexes(reserved)
      fixed = {}
      reserved.entries.each do |index, color|
        next if index == reserved.transparent_index || Color.fully_transparent?(color)

        fixed[color] = index
      end
      fixed
    end

    def map_images(images, palette_colors, fixed_indexes, active_indexes, transparent_index)
      images.map do |pixels|
        pixels.map do |pixel|
          color = Color.parse(pixel)
          next transparent_index if Color.fully_transparent?(color)
          next fixed_indexes[color] if fixed_indexes.key?(color)

          active_indexes.values.min_by do |palette_index|
            [squared_distance(color, palette_colors[palette_index]), palette_index]
          end
        end
      end
    end

    def squared_distance(left, right)
      4.times.map { |channel| (component(left, channel) - component(right, channel))**2 }.inject(0, :+)
    end

    def component(color, channel)
      case channel
      when 0 then Color.r(color)
      when 1 then Color.g(color)
      when 2 then Color.b(color)
      when 3 then Color.a(color)
      end
    end

    class ReservedPalette
      attr_reader :entries, :transparent_index

      def initialize(entries, transparent_index)
        @entries = entries.sort_by(&:first)
        @transparent_index = transparent_index
      end

      def colors
        entries.map(&:last)
      end

      def size
        entries.length
      end

      def reject(&block)
        entries.reject(&block)
      end
    end
  end

  PaletteQuantizer = Quantizer
  class << self
    def quantize(images, options = {})
      Quantizer.quantize(images, options)
    end
  end
end
