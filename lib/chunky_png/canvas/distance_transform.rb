# frozen-string-literal: true

module ChunkyPNG
  class Canvas
    # The ChunkyPNG::Canvas::DistanceTransform module adds computation of a
    # signed Euclidean distance field of the canvas' alpha channel, e.g. for
    # font post-processing. It is a thin wrapper around
    # {ChunkyPNG::DistanceTransform}, so both entry points share the exact
    # same conventions and implementation.
    #
    # @see ChunkyPNG::DistanceTransform
    module DistanceTransform
      # Computes the signed Euclidean distance field of this canvas' alpha
      # channel.
      #
      # The alpha channel is thresholded into a binary mask: every pixel
      # with an alpha value greater than or equal to +threshold+ counts as
      # foreground (inside), all other pixels as background (outside). The
      # mask is then transformed with
      # {ChunkyPNG::DistanceTransform.signed_distance_field}; see that
      # method for the exact conventions on pixel centers, sign, empty and
      # full masks, and the image boundary.
      #
      # In short, the returned value per pixel is positive for foreground
      # pixels and negative for background pixels, with an absolute value
      # equal to the Euclidean distance from the pixel's center to the
      # center of the nearest pixel of the opposite class.
      #
      # @param [Integer] threshold The alpha value at which a pixel counts
      #   as foreground. Defaults to 128.
      # @return [Array<Float>] Flat array of +width * height+ signed
      #   distances in row-major order, matching the order of {#pixels}.
      # @see ChunkyPNG::DistanceTransform.signed_distance_field
      def signed_distance_field(threshold = 128)
        mask = pixels.map { |pixel| ChunkyPNG::Color.a(pixel) >= threshold }
        ChunkyPNG::DistanceTransform.signed_distance_field(mask, width, height)
      end
    end
  end
end
