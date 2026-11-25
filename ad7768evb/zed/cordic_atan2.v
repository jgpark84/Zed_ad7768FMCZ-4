module cordic_atan2 (
  input  wire               clk,
  input  wire               rst,
  input  wire               in_valid,

  input  wire signed [31:0] x_in,
  input  wire signed [31:0] y_in,

  output reg  signed [31:0] phase,
  output reg                out_valid,
  output reg                busy
);

  reg signed [34:0] x;
  reg signed [34:0] y;
  reg signed [31:0] z;

  reg [5:0] iter;

  function [31:0] atan_lut;
    input [5:0] index;
    begin
      case (index)
        6'd0:  atan_lut = 32'h20000000;
        6'd1:  atan_lut = 32'h12E4051E;
        6'd2:  atan_lut = 32'h09FB385B;
        6'd3:  atan_lut = 32'h051111D4;
        6'd4:  atan_lut = 32'h028B0D43;
        6'd5:  atan_lut = 32'h0145D7E1;
        6'd6:  atan_lut = 32'h00A2F61E;
        6'd7:  atan_lut = 32'h00517C55;
        6'd8:  atan_lut = 32'h0028BE53;
        6'd9:  atan_lut = 32'h00145F2F;
        6'd10: atan_lut = 32'h000A2F98;
        6'd11: atan_lut = 32'h000517CC;
        6'd12: atan_lut = 32'h00028BE6;
        6'd13: atan_lut = 32'h000145F3;
        6'd14: atan_lut = 32'h0000A2FA;
        6'd15: atan_lut = 32'h0000517D;
        6'd16: atan_lut = 32'h000028BE;
        6'd17: atan_lut = 32'h0000145F;
        6'd18: atan_lut = 32'h00000A30;
        6'd19: atan_lut = 32'h00000518;
        6'd20: atan_lut = 32'h0000028C;
        6'd21: atan_lut = 32'h00000146;
        6'd22: atan_lut = 32'h000000A3;
        6'd23: atan_lut = 32'h00000051;
        6'd24: atan_lut = 32'h00000029;
        6'd25: atan_lut = 32'h00000014;
        6'd26: atan_lut = 32'h0000000A;
        6'd27: atan_lut = 32'h00000005;
        6'd28: atan_lut = 32'h00000003;
        6'd29: atan_lut = 32'h00000001;
        6'd30: atan_lut = 32'h00000001;
        default: atan_lut = 32'd0;
      endcase
    end
  endfunction


  always @(posedge clk) begin

    out_valid <= 1'b0;

    if (rst) begin

      x         <= 35'sd0;
      y         <= 35'sd0;
      z         <= 32'sd0;
      phase     <= 32'sd0;
      iter      <= 6'd0;
      busy      <= 1'b0;
      out_valid <= 1'b0;

    end else begin

      // -------------------------------------------------------------
      // Start new conversion
      // -------------------------------------------------------------

      if (in_valid && !busy) begin

        iter <= 6'd0;
        busy <= 1'b1;

        // Move left-half-plane vectors to right half-plane
        // and pre-load +/- pi.
        if (x_in[31]) begin

          x <= -{{3{x_in[31]}}, x_in};
          y <= -{{3{y_in[31]}}, y_in};

          if (!y_in[31])
            z <= 32'sh80000000;   // +pi modulo representation
          else
            z <= 32'sh80000000;   // -pi has same 32-bit phase boundary

        end else begin

          x <= {{3{x_in[31]}}, x_in};
          y <= {{3{y_in[31]}}, y_in};
          z <= 32'sd0;

        end

      end

      // -------------------------------------------------------------
      // Vectoring CORDIC
      // -------------------------------------------------------------

      else if (busy) begin

        if (y >= 0) begin

          x <= x + (y >>> iter);
          y <= y - (x >>> iter);
          z <= z + $signed(atan_lut(iter));

          if (iter == 6'd30) begin
            phase     <= z + $signed(atan_lut(iter));
            out_valid <= 1'b1;
            busy      <= 1'b0;
          end

        end else begin

          x <= x - (y >>> iter);
          y <= y + (x >>> iter);
          z <= z - $signed(atan_lut(iter));

          if (iter == 6'd30) begin
            phase     <= z - $signed(atan_lut(iter));
            out_valid <= 1'b1;
            busy      <= 1'b0;
          end

        end

        iter <= iter + 1'b1;

      end
    end
  end

endmodule