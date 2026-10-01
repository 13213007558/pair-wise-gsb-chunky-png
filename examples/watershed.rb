# frozen-string-literal: true

# Example: marker-controlled watershed segmentation of a height map.
#
# Generates spec/resources/watershed_segmentation.png, showing the height
# map on the left and the segmented regions on the right.
#
# Run from the repository root with:
#
#   ruby -Ilib examples/watershed.rb

require "chunky_png"

width, height = 64, 48
basins = [[20, 24], [52, 24], [46, 44]]
gauss = ->(x, y, cx, cy) { 140.0 * Math.exp(-((x - cx)**2 + (y - cy)**2) / 260.0) }

# Landscape with three basins; the minima coincide with the marker positions.
heights = Array.new(height) do |y|
  Array.new(width) do |x|
    (200 - basins.map { |cx, cy| gauss.call(x, y, cx, cy) }.max).round
  end
end

markers = Array.new(height) { Array.new(width, 0) }
basins.each_with_index { |(mx, my), index| markers[my][mx] = index + 1 }

result = ChunkyPNG::Watershed.segment(heights, markers, connectivity: 8)

height_canvas = ChunkyPNG::Canvas.new(width, height)
min, max = heights.flatten.minmax
height.times do |y|
  width.times do |x|
    gray = ((heights[y][x] - min) * 255.0 / (max - min)).round
    height_canvas[x, y] = ChunkyPNG::Color.grayscale(gray)
  end
end

segmentation = result.to_image
basins.each { |mx, my| segmentation[mx, my] = ChunkyPNG::Color::WHITE }

combined = ChunkyPNG::Canvas.new(width * 2 + 1, height, ChunkyPNG::Color::WHITE)
combined.compose!(height_canvas, 0, 0)
combined.compose!(segmentation, width + 1, 0)
combined.resample_nearest_neighbor!(combined.width * 4, combined.height * 4)
combined.save(File.expand_path("../spec/resources/watershed_segmentation.png", __dir__))
