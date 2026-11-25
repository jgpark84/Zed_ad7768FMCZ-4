module input_normalizer (
  input  wire               clk,
  input  wire               rst,
  input  wire               in_valid,

  input  wire signed [31:0] source_data,
  input  wire signed [31:0] center,
  input  wire signed [31:0] scale,

  output reg  signed [31:0] normalized_data,
  output reg                out_valid
);

  // scale is Q16.16.
  // center and source_data use the native signed integer representation
  // of the selected input source.
  //
  // This block does NOT calculate center or scale. They are configuration
  // values written by software and treated as constants by the realtime path.
  //
  // normalized = (source_data - center) * scale
  //              --------------------------------
  //                           2^16
  //
  // The subtraction is kept at 33 bits so a valid signed32 subtraction cannot
  // overflow before scaling. The final result is saturated to signed32.

  reg signed [32:0] diff_s0;
  reg signed [31:0] scale_s0;
  reg               v0;

  reg signed [64:0] product_s1;
  reg               v1;

  wire signed [64:0] scaled_w = $signed(product_s1) >>> 16;

  localparam signed [64:0] SIGNED32_MAX = 65'sd2147483647;
  localparam signed [64:0] SIGNED32_MIN = -65'sd2147483648;

  always @(posedge clk) begin

    if (rst) begin

      diff_s0         <= 33'sd0;
      scale_s0        <= 32'sd0;
      product_s1      <= 65'sd0;
      normalized_data <= 32'sd0;
      out_valid       <= 1'b0;
      v0              <= 1'b0;
      v1              <= 1'b0;

    end else begin

      out_valid <= 1'b0;

      v0 <= in_valid;
      v1 <= v0;

      if (in_valid) begin
        diff_s0 <=
          $signed({source_data[31], source_data}) -
          $signed({center[31], center});

        scale_s0 <= scale;
      end

      if (v0) begin
        product_s1 <=
          $signed(diff_s0) *
          $signed(scale_s0);
      end

      if (v1) begin

        if ($signed(scaled_w) > $signed(SIGNED32_MAX))
          normalized_data <= 32'sh7FFFFFFF;

        else if ($signed(scaled_w) < $signed(SIGNED32_MIN))
          normalized_data <= 32'sh80000000;

        else
          normalized_data <= scaled_w[31:0];

        out_valid <= 1'b1;
      end

    end
  end

endmodule
