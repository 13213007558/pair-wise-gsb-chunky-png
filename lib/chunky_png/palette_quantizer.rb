# frozen_string_literal: true

module ChunkyPNG
  class PaletteQuantizer
    attr_reader :images, :size, :weights, :fixed_colors, :transparent_index

    def self.quantize(images, options = {})
      new(images, options).quantize
    end

    def initialize(images, options = {})
      @images = images.respond_to?(:pixels) ? [images] : images.to_a
      raise ArgumentError, "At least one image is required for quantization." if @images.empty?

      @size = Integer(options.fetch(:size, options.fetch(:palette_size, 64)))
      raise ArgumentError, "Palette size must be between 1 and 256." unless @size.between?(1, 256)

      @weights = extract_weights(options[:weights] || options[:image_weights])
      @fixed_colors, implicit_transparent_index =
        extract_fixed_colors(options[:fixed_colors] || options[:brand_colors] || options[:fixed])
      @transparent_index = options[:transparent_index] || options[:transparent_slot] || implicit_transparent_index
      @transparent_index = first_available_index if @transparent_index.nil?
      validate_reserved_slots!
    end

    def quantize
      histogram = weighted_histogram
      free_centroids = refine_centroids(histogram, initial_free_centroids(histogram))
      palette_colors = build_palette(free_centroids)
      palette = Palette.from_ordered_colors(palette_colors)
      indices = images.map { |image| map_pixels(image, palette_colors) }
      [palette, indices]
    end

    private

    def extract_weights(value)
      values = value.is_a?(Numeric) ? Array.new(images.length, value) : (value || Array.new(images.length, 1)).to_a
      if values.length != images.length
        raise ArgumentError,
          "The number of weights (#{values.length}) does not match the number of images (#{images.length})."
      end

      values.map do |weight|
        weight = Float(weight)
        raise ArgumentError, "Image weights cannot be negative." if weight < 0

        weight
      end
    end

    def extract_fixed_colors(value)
      fixed = {}
      transparent_index = nil
      entries = value.is_a?(Hash) ? fixed_hash_entries(value) : fixed_array_entries(value)

      entries.sort_by(&:first).each do |index, color|
        unless index.between?(0, size - 1)
          raise ArgumentError, "Fixed color index #{index} is outside the palette."
        end

        if Color.fully_transparent?(color)
          if transparent_index && transparent_index != index
            raise ArgumentError, "The transparent slot cannot be at both #{transparent_index} and #{index}."
          end
          transparent_index = index
        elsif fixed.value?(color)
          raise ArgumentError, "Fixed color #{Color.to_hex(color)} was specified more than once."
        else
          fixed[index] = color
        end
      end

      [fixed, transparent_index]
    end

    def fixed_hash_entries(value)
      value.map { |index, color| [Integer(index), parse_color(color)] }
    end

    def fixed_array_entries(value)
      Array(value).each_with_index.map { |color, index| [index, parse_color(color)] }
    end

    def parse_color(value)
      color = Color.parse(value)
      Color.fully_transparent?(color) ? Color::TRANSPARENT : color
    end

    def first_available_index
      index = 0
      index += 1 while fixed_colors.key?(index)
      index
    end

    def validate_reserved_slots!
      unless transparent_index.between?(0, size - 1)
        raise ArgumentError, "Transparent index #{transparent_index} is outside the palette."
      end
      if fixed_colors.key?(transparent_index)
        raise ArgumentError, "Transparent index #{transparent_index} is already used by a fixed color."
      end
      if fixed_colors.size + 1 > size
        raise ArgumentError, "The palette has too many reserved slots."
      end
    end

    def image_pixels(image)
      image.respond_to?(:pixels) ? image.pixels : image.to_a
    end

    def weighted_histogram
      histogram = Hash.new(0.0)
      images.each_with_index do |image, image_index|
        image_pixels(image).each do |pixel|
          color = parse_color(pixel)
          next if Color.fully_transparent?(color)

          histogram[color] += weights[image_index]
        end
      end
      histogram
    end

    def free_indices
      @free_indices ||= (0...size).reject { |index| fixed_colors.key?(index) || index == transparent_index }
    end

    def initial_free_centroids(histogram)
      points = histogram.reject { |_, weight| weight.zero? }
        .map { |color, weight| [components(color), weight] }
        .sort_by(&:first)
      centroids = median_cut_boxes(points, free_indices.length).map { |box| weighted_average(box) }
      pad_components(centroids, free_indices.length)
    end

    def median_cut_boxes(points, count)
      return [] if points.empty?

      boxes = [points]
      while boxes.length < count
        box_index = boxes.each_with_index.max_by { |box, _| [box_range(box), box_weight(box)] }.last
        split = split_box(boxes[box_index], largest_channel(boxes[box_index]))
        break if split.nil?

        boxes[box_index, 1] = split
      end
      boxes
    end

    def box_range(box)
      4.times.map { |channel| channel_range(box, channel) }.max
    end

    def largest_channel(box)
      4.times.max_by { |channel| [channel_range(box, channel), -channel] }
    end

    def channel_range(box, channel)
      values = box.map { |point, _| point[channel] }
      values.max - values.min
    end

    def box_weight(box)
      box.reduce(0.0) { |total, (_, weight)| total + weight }
    end

    def split_box(box, channel)
      sorted = box.sort_by { |point, weight| [point[channel], point, -weight] }
      return nil if sorted.length < 2 || sorted.first[0][channel] == sorted.last[0][channel]

      target = box_weight(sorted) / 2.0
      cumulative = 0.0
      split_at = sorted.index do |_, weight|
        cumulative += weight
        cumulative >= target
      end || sorted.length - 1
      split_at = 1 if split_at.zero?

      while split_at < sorted.length && sorted[split_at - 1][0][channel] == sorted[split_at][0][channel]
        split_at += 1
      end
      return nil if split_at == sorted.length

      [sorted[0...split_at], sorted[split_at..-1]]
    end

    def weighted_average(box)
      total = box_weight(box)
      return components(fixed_colors.values.first || Color::BLACK) if total.zero?

      Array.new(4) do |channel|
        weighted_sum = box.reduce(0.0) { |sum, (point, weight)| sum + (point[channel] * weight) }
        clamp((weighted_sum / total).round)
      end
    end

    def refine_centroids(histogram, free_centroids)
      centroids = initial_centroid_map(free_centroids)
      samples = histogram.reject { |_, weight| weight.zero? }.map { |color, weight| [components(color), weight] }
      previous = nil
      iterations = 0

      while previous != centroids && iterations < 20
        previous = centroids.map(&:dup)
        assignments = assign_samples(samples, centroids)
        centroids = centroids.each_with_index.map do |centroid, index|
          fixed_colors.key?(index) ? centroid : average_or_keep(centroid, assignments[index])
        end
        centroids = ensure_unique_free_centroids(centroids)
        iterations += 1
      end

      free_indices.map { |index| centroids[index] }
    end

    def initial_centroid_map(free_centroids)
      centroids = Array.new(size)
      fixed_colors.each { |index, color| centroids[index] = components(color) }
      free_indices.each_with_index { |index, position| centroids[index] = free_centroids[position] }
      centroids
    end

    def assign_samples(samples, centroids)
      assignments = Array.new(size) { [] }
      samples.each do |point, weight|
        assignments[nearest_component_index(point, centroids)] << [point, weight]
      end
      assignments
    end

    def average_or_keep(centroid, assigned)
      return centroid if assigned.empty?

      total = assigned.reduce(0.0) { |sum, (_, weight)| sum + weight }
      Array.new(4) do |channel|
        weighted_sum = assigned.reduce(0.0) { |sum, (point, weight)| sum + (point[channel] * weight) }
        clamp((weighted_sum / total).round)
      end
    end

    def ensure_unique_free_centroids(centroids)
      result = centroids.dup
      used = {}
      fixed_colors.each_value { |color| used[components(color)] = true }
      result.each_with_index do |centroid, index|
        next if centroid.nil? || fixed_colors.key?(index)

        result[index] = next_unused_component(used.keys) if used.key?(centroid)
        used[result[index]] = true
      end
      result
    end

    def pad_components(centroids, count)
      existing = centroids.dup
      while centroids.length < count
        centroids << next_unused_component(existing)
        existing = centroids.dup
      end
      centroids.first(count)
    end

    def next_unused_component(existing)
      fallback_components.find { |candidate| !existing.include?(candidate) }
    end

    def fallback_components
      @fallback_components ||= (0...256).map do |index|
        [((index / 32) % 8) * 36, ((index / 4) % 8) * 36, (index % 4) * 84, 255]
      end
    end

    def build_palette(free_centroids)
      colors = Array.new(size)
      fixed_colors.each { |index, color| colors[index] = color }
      colors[transparent_index] = Color::TRANSPARENT
      free_indices.each_with_index { |index, position| colors[index] = color_from_components(free_centroids[position]) }

      used = fixed_colors.values.each_with_object({}) { |color, occupied| occupied[color] = true }
      used[Color::TRANSPARENT] = true
      colors.each_with_index do |color, index|
        next if color.nil?

        if !fixed_colors.key?(index) && index != transparent_index && used.key?(color)
          color = next_unused_color(colors)
        end
        colors[index] = color
        used[color] = true
      end
      colors
    end

    def next_unused_color(colors)
      existing = colors.reject(&:nil?).map { |color| components(color) }
      color_from_components(next_unused_component(existing))
    end

    def map_pixels(image, palette_colors)
      image_pixels(image).map do |pixel|
        color = parse_color(pixel)
        next transparent_index if Color.fully_transparent?(color)

        nearest_color_index(color, palette_colors)
      end
    end

    def nearest_color_index(color, palette_colors)
      point = components(color)
      best_index = nil
      best_distance = nil
      palette_colors.each_with_index do |palette_color, index|
        next if index == transparent_index

        distance = squared_distance(point, components(palette_color))
        if best_distance.nil? || distance < best_distance
          best_distance = distance
          best_index = index
        end
      end
      best_index
    end

    def nearest_component_index(point, centroids)
      best_index = nil
      best_distance = nil
      centroids.each_with_index do |centroid, index|
        next if centroid.nil?

        distance = squared_distance(point, centroid)
        if best_distance.nil? || distance < best_distance
          best_distance = distance
          best_index = index
        end
      end
      best_index
    end

    def components(color)
      [Color.r(color), Color.g(color), Color.b(color), Color.a(color)]
    end

    def color_from_components(values)
      Color.rgba(values[0], values[1], values[2], values[3])
    end

    def squared_distance(first, second)
      4.times.reduce(0) { |sum, channel| sum + (first[channel] - second[channel])**2 }
    end

    def clamp(value)
      return 0 if value < 0
      return 255 if value > 255

      value
    end
  end
end
