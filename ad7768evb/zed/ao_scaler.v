module ao_scaler (
  input  wire               clk,

  input  wire signed [31:0] source_data,

  input  wire signed [31:0] gain,
  input  wire signed [31:0] offset,

  input  wire signed [31:0] out_min,
  input  wire signed [31:0] out_max,

  output reg         [15:0] output_code,
  output reg         [31:0] status
);

  // ================================================================
  // Stage 1
  // source_data * gain
  // ================================================================

  reg signed [63:0] product_s1;

  reg signed [31:0] offset_s1;
  reg signed [31:0] out_min_s1;
  reg signed [31:0] out_max_s1;


  // ================================================================
  // Stage 2 combinational result
  // ================================================================

  reg signed [63:0] scaled_s2;

  reg        [15:0] output_code_next;
  reg        [31:0] status_next;


  // ================================================================
  // Stage 1
  //
  // Q16.16 multiplication.
  // The configuration is captured together with the source sample so
  // all values used by stage 2 belong to the same scaler transaction.
  // ================================================================

  always @(posedge clk) begin

    product_s1 <=
      $signed(source_data) *
      $signed(gain);

    offset_s1  <= offset;
    out_min_s1 <= out_min;
    out_max_s1 <= out_max;

  end


  // ================================================================
  // Stage 2 combinational logic
  // ================================================================

  always @(*) begin

    scaled_s2 =
      ($signed(product_s1) >>> 16) +
      $signed(offset_s1);

    output_code_next = 16'h0000;
    status_next      = 32'd0;


    // ------------------------------------------------------------
    // User-defined lower limit
    // ------------------------------------------------------------

    if (scaled_s2 < $signed(out_min_s1)) begin

      if ($signed(out_min_s1) < 0)
        output_code_next = 16'h0000;

      else if ($signed(out_min_s1) > 32'sd65535)
        output_code_next = 16'hFFFF;

      else
        output_code_next = out_min_s1[15:0];

      status_next[0] = 1'b1;

    end


    // ------------------------------------------------------------
    // User-defined upper limit
    // ------------------------------------------------------------

    else if (scaled_s2 > $signed(out_max_s1)) begin

      if ($signed(out_max_s1) < 0)
        output_code_next = 16'h0000;

      else if ($signed(out_max_s1) > 32'sd65535)
        output_code_next = 16'hFFFF;

      else
        output_code_next = out_max_s1[15:0];

      status_next[1] = 1'b1;

    end


    // ------------------------------------------------------------
    // Physical DAC lower limit
    // ------------------------------------------------------------

    else if (scaled_s2 < 0) begin

      output_code_next = 16'h0000;
      status_next[0]   = 1'b1;

    end


    // ------------------------------------------------------------
    // Physical DAC upper limit
    // ------------------------------------------------------------

    else if (scaled_s2 > 64'sd65535) begin

      output_code_next = 16'hFFFF;
      status_next[1]   = 1'b1;

    end


    // ------------------------------------------------------------
    // Normal output
    // ------------------------------------------------------------

    else begin

      output_code_next = scaled_s2[15:0];

    end

  end


  // ================================================================
  // Final output register
  // ================================================================

  always @(posedge clk) begin

    output_code <= output_code_next;
    status      <= status_next;

  end

endmodule