// 20-bit AO scaler for AD5791 / EVAL-CN0531-PMDZ.
//
// Interface and pipeline match the existing ao_scaler.v (16-bit):
//   Stage 1: signed 32x32 multiplication and configuration capture.
//   Stage 2: arithmetic Q16.16 shift, signed offset, user-limit clamp,
//            physical DAC-limit clamp, registered output/status.
//
// NOTE: gain uses Q16.16; source_data, offset and limits are integer
// DAC-code units. The output is an UNSIGNED 20-bit DAC code (0..0xFFFFF).
// In the CN0531 bipolar configuration 0x80000 is approximately 0 V.
//
// No source-selection logic is placed here. Manual/PID selection is made
// upstream, exactly as for the existing 16-bit AO scaler.
// No reset/valid signal is added: output latency is two clock edges,
// identical to the existing ao_scaler.v.
module ao_scaler_20bit (
  input  wire               clk,

  input  wire signed [31:0] source_data,

  input  wire signed [31:0] gain,
  input  wire signed [31:0] offset,

  input  wire signed [31:0] out_min,
  input  wire signed [31:0] out_max,

  output reg         [19:0] output_code,
  output reg         [31:0] status
);

  // Stage 1: capture source * gain and its matching configuration.
  reg signed [63:0] product_s1;
  reg signed [31:0] offset_s1;
  reg signed [31:0] out_min_s1;
  reg signed [31:0] out_max_s1;

  // Stage 2: combinational scaling and clamping.
  reg signed [63:0] scaled_s2;
  reg        [19:0] output_code_next;
  reg        [31:0] status_next;

  localparam signed [63:0] DAC_MAX = 64'sd1048575;

  always @(posedge clk) begin
    product_s1 <= $signed(source_data) * $signed(gain);
    offset_s1  <= offset;
    out_min_s1 <= out_min;
    out_max_s1 <= out_max;
  end

  always @(*) begin
    scaled_s2 = ($signed(product_s1) >>> 16) + $signed(offset_s1);

    output_code_next = 20'h00000;
    status_next      = 32'd0;

    // Preserve the original 16-bit scaler's clamp precedence/status:
    // user lower bound, user upper bound, physical lower, physical upper.
    // status[0] = lower clamp; status[1] = upper clamp.
    if (scaled_s2 < $signed(out_min_s1)) begin
      if ($signed(out_min_s1) < 0)
        output_code_next = 20'h00000;
      else if ($signed(out_min_s1) > DAC_MAX)
        output_code_next = 20'hFFFFF;
      else
        output_code_next = out_min_s1[19:0];

      status_next[0] = 1'b1;
    end
    else if (scaled_s2 > $signed(out_max_s1)) begin
      if ($signed(out_max_s1) < 0)
        output_code_next = 20'h00000;
      else if ($signed(out_max_s1) > DAC_MAX)
        output_code_next = 20'hFFFFF;
      else
        output_code_next = out_max_s1[19:0];

      status_next[1] = 1'b1;
    end
    else if (scaled_s2 < 0) begin
      output_code_next = 20'h00000;
      status_next[0]   = 1'b1;
    end
    else if (scaled_s2 > DAC_MAX) begin
      output_code_next = 20'hFFFFF;
      status_next[1]   = 1'b1;
    end
    else begin
      output_code_next = scaled_s2[19:0];
    end
  end

  // Final output register: matches existing ao_scaler.v's pipeline.
  always @(posedge clk) begin
    output_code <= output_code_next;
    status      <= status_next;
  end

endmodule
