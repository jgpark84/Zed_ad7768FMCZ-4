module app_ctrl_reg (
  input              up_rstn,
  input              up_clk,

  input              up_wreq,
  input      [6:0]   up_waddr,
  input      [31:0]  up_wdata,
  output reg         up_wack,

  input              up_rreq,
  input      [6:0]   up_raddr,
  output reg [31:0]  up_rdata,
  output reg         up_rack,

  // =========================================================================
  // Common configuration
  // =========================================================================

  output wire [15:0] dac_code,           // legacy = AO0 manual code
  output reg  [3:0]  avg_shift,

  // =========================================================================
  // CORDIC configuration
  // =========================================================================

  output reg  [5:0]  cordic_sel_x,
  output reg  [5:0]  cordic_sel_y,

  // =========================================================================
  // PID configuration
  // =========================================================================

  output reg  [3:0]   pid_enable,
  output reg  [3:0]   pid_reset_toggle,
  output reg  [7:0]   pid_input_sel,

  output reg  [127:0] pid_input_center,
  output reg  [127:0] pid_input_scale,
  output reg  [127:0] pid_setpoint,

  output reg  [127:0] pid_kp,
  output reg  [127:0] pid_ki,
  output reg  [127:0] pid_kd,

  output reg  [127:0] pid_out_min,
  output reg  [127:0] pid_out_max,

  // =========================================================================
  // AO configuration
  // =========================================================================

  output reg  [11:0]  ao_source_sel,
  output reg  [63:0]  ao_manual_code,

  output reg  [127:0] ao_gain,
  output reg  [127:0] ao_offset,
  output reg  [127:0] ao_out_min,
  output reg  [127:0] ao_out_max,

  // One-way APPLY event into the ADC/control clock domain.
  output reg           apply_toggle
);

  // Keep old 0x000 interface alive, but use the exact same storage as
  // AO0 manual code. No duplicate state.
  // =========================================================================

  assign dac_code = ao_manual_code[15:0];


  // =========================================================================
  // WRITE
  // =========================================================================

  always @(posedge up_clk) begin

    if (!up_rstn) begin

      up_wack <= 1'b0;

      apply_toggle <= 1'b0;

      // ---------------------------------------------------------------------
      // Common
      // ---------------------------------------------------------------------

      avg_shift <= 4'd4;                 // N = 16

      // ---------------------------------------------------------------------
      // CORDIC defaults
      // ---------------------------------------------------------------------

      cordic_sel_x[1:0] <= 2'd0;
      cordic_sel_y[1:0] <= 2'd1;

      cordic_sel_x[3:2] <= 2'd2;
      cordic_sel_y[3:2] <= 2'd3;

      cordic_sel_x[5:4] <= 2'd0;
      cordic_sel_y[5:4] <= 2'd1;

      // ---------------------------------------------------------------------
      // PID defaults
      // ---------------------------------------------------------------------

      pid_enable      <= 4'b0000;
      pid_reset_toggle <= 4'd0;

      pid_input_sel <= {
        2'd1,    // PID3
        2'd0,    // PID2
        2'd1,    // PID1
        2'd0     // PID0
      };

      pid_input_center <= 128'd0;
      pid_input_scale <= {
        32'h00010000,
        32'h00010000,
        32'h00010000,
        32'h00010000
      };
      pid_setpoint     <= 128'd0;

      pid_kp <= 128'd0;
      pid_ki <= 128'd0;
      pid_kd <= 128'd0;

      pid_out_min <= {
        32'h80000000,
        32'h80000000,
        32'h80000000,
        32'h80000000
      };

      pid_out_max <= {
        32'h7FFFFFFF,
        32'h7FFFFFFF,
        32'h7FFFFFFF,
        32'h7FFFFFFF
      };

      // ---------------------------------------------------------------------
      // AO defaults
      // ---------------------------------------------------------------------

      ao_source_sel <= 12'd0;            // all manual

      ao_manual_code <= {
        16'h8000,
        16'h8000,
        16'h8000,
        16'h8000
      };

      ao_gain <= {
        32'h00010000,
        32'h00010000,
        32'h00010000,
        32'h00010000
      };
      ao_offset <= 128'd0;

      ao_out_min <= {
        32'h00000000,
        32'h00000000,
        32'h00000000,
        32'h00000000
      };

      ao_out_max <= {
        32'h0000FFFF,
        32'h0000FFFF,
        32'h0000FFFF,
        32'h0000FFFF
      };

    end else begin

      up_wack <= 1'b0;


      if (up_wreq) begin

        // ===================================================================
        // Common / CORDIC
        // ===================================================================

        case (up_waddr)

          // ---------------------------------------------------------------
          // 0x000 : legacy DAC code = AO0 manual code
          // ---------------------------------------------------------------

          7'h00:
            ao_manual_code[15:0] <= up_wdata[15:0];


          // ---------------------------------------------------------------
          // 0x014 : averaging shift
          // ---------------------------------------------------------------

          7'h05: begin
            if (up_wdata[3:0] <= 4'd10)
              avg_shift <= up_wdata[3:0];
            else
              avg_shift <= 4'd10;
          end


          // ---------------------------------------------------------------
          // CORDIC selectors
          // ---------------------------------------------------------------

          7'h06: cordic_sel_x[1:0] <= up_wdata[1:0];   // 0x018
          7'h07: cordic_sel_y[1:0] <= up_wdata[1:0];   // 0x01C

          7'h08: cordic_sel_x[3:2] <= up_wdata[1:0];   // 0x020
          7'h09: cordic_sel_y[3:2] <= up_wdata[1:0];   // 0x024

          7'h0A: cordic_sel_x[5:4] <= up_wdata[1:0];   // 0x028
          7'h0B: cordic_sel_y[5:4] <= up_wdata[1:0];   // 0x02C

          // ---------------------------------------------------------------
          // 0x1C0 : APPLY_CMD (write-1 event semantics)
          // bit0 = APPLY
          // ---------------------------------------------------------------
          7'h70: begin
            if (up_wdata[0])
              apply_toggle <= ~apply_toggle;
          end

          default: begin
          end

        endcase


        // ===================================================================
        // PID blocks
        //
        // word blocks:
        //
        // PID0 = 0x10 ~ 0x1F  -> byte 0x040
        // PID1 = 0x20 ~ 0x2F  -> byte 0x080
        // PID2 = 0x30 ~ 0x3F  -> byte 0x0C0
        // PID3 = 0x40 ~ 0x4F  -> byte 0x100
        // ===================================================================

        if ((up_waddr[6:4] >= 3'd1) &&
            (up_waddr[6:4] <= 3'd4)) begin

          case (up_waddr[3:0])

            // +0x00 CONTROL
            //
            // bit0 = enable
            // bit1 = reset toggle
            //
            4'h0: begin

              case (up_waddr[6:4])

                3'd1: begin
                  pid_enable[0] <= up_wdata[0];

                  if (up_wdata[1])
                    pid_reset_toggle[0] <= ~pid_reset_toggle[0];
                end

                3'd2: begin
                  pid_enable[1] <= up_wdata[0];

                  if (up_wdata[1])
                    pid_reset_toggle[1] <= ~pid_reset_toggle[1];
                end

                3'd3: begin
                  pid_enable[2] <= up_wdata[0];

                  if (up_wdata[1])
                    pid_reset_toggle[2] <= ~pid_reset_toggle[2];
                end

                3'd4: begin
                  pid_enable[3] <= up_wdata[0];

                  if (up_wdata[1])
                    pid_reset_toggle[3] <= ~pid_reset_toggle[3];
                end

              endcase
            end


            // +0x04 INPUT SELECT
            4'h1: begin

              case (up_waddr[6:4])
                3'd1: pid_input_sel[1:0] <= up_wdata[1:0];
                3'd2: pid_input_sel[3:2] <= up_wdata[1:0];
                3'd3: pid_input_sel[5:4] <= up_wdata[1:0];
                3'd4: pid_input_sel[7:6] <= up_wdata[1:0];
              endcase

            end


            // +0x08 INPUT CENTER
            4'h2: begin

              case (up_waddr[6:4])
                3'd1: pid_input_center[31:0]   <= up_wdata;
                3'd2: pid_input_center[63:32]  <= up_wdata;
                3'd3: pid_input_center[95:64]  <= up_wdata;
                3'd4: pid_input_center[127:96] <= up_wdata;
              endcase

            end


            // +0x0C INPUT SCALE
            4'h3: begin

              case (up_waddr[6:4])
                3'd1: pid_input_scale[31:0]   <= up_wdata;
                3'd2: pid_input_scale[63:32]  <= up_wdata;
                3'd3: pid_input_scale[95:64]  <= up_wdata;
                3'd4: pid_input_scale[127:96] <= up_wdata;
              endcase

            end


            // +0x10 SETPOINT
            4'h4: begin

              case (up_waddr[6:4])
                3'd1: pid_setpoint[31:0]   <= up_wdata;
                3'd2: pid_setpoint[63:32]  <= up_wdata;
                3'd3: pid_setpoint[95:64]  <= up_wdata;
                3'd4: pid_setpoint[127:96] <= up_wdata;
              endcase

            end


            // +0x14 KP
            4'h5: begin

              case (up_waddr[6:4])
                3'd1: pid_kp[31:0]   <= up_wdata;
                3'd2: pid_kp[63:32]  <= up_wdata;
                3'd3: pid_kp[95:64]  <= up_wdata;
                3'd4: pid_kp[127:96] <= up_wdata;
              endcase

            end


            // +0x18 KI
            4'h6: begin

              case (up_waddr[6:4])
                3'd1: pid_ki[31:0]   <= up_wdata;
                3'd2: pid_ki[63:32]  <= up_wdata;
                3'd3: pid_ki[95:64]  <= up_wdata;
                3'd4: pid_ki[127:96] <= up_wdata;
              endcase

            end


            // +0x1C KD
            4'h7: begin

              case (up_waddr[6:4])
                3'd1: pid_kd[31:0]   <= up_wdata;
                3'd2: pid_kd[63:32]  <= up_wdata;
                3'd3: pid_kd[95:64]  <= up_wdata;
                3'd4: pid_kd[127:96] <= up_wdata;
              endcase

            end


            // +0x20 OUTPUT MIN
            4'h8: begin

              case (up_waddr[6:4])
                3'd1: pid_out_min[31:0]   <= up_wdata;
                3'd2: pid_out_min[63:32]  <= up_wdata;
                3'd3: pid_out_min[95:64]  <= up_wdata;
                3'd4: pid_out_min[127:96] <= up_wdata;
              endcase

            end


            // +0x24 OUTPUT MAX
            4'h9: begin

              case (up_waddr[6:4])
                3'd1: pid_out_max[31:0]   <= up_wdata;
                3'd2: pid_out_max[63:32]  <= up_wdata;
                3'd3: pid_out_max[95:64]  <= up_wdata;
                3'd4: pid_out_max[127:96] <= up_wdata;
              endcase

            end

            default: begin
            end

          endcase
        end


        // ===================================================================
        // AO blocks
        //
        // AO0 = 0x50 ~ 0x57 -> byte 0x140
        // AO1 = 0x58 ~ 0x5F -> byte 0x160
        // AO2 = 0x60 ~ 0x67 -> byte 0x180
        // AO3 = 0x68 ~ 0x6F -> byte 0x1A0
        // ===================================================================

        if ((up_waddr >= 7'h50) &&
            (up_waddr <= 7'h6F)) begin

          case (up_waddr[2:0])

            // +0x00 SOURCE SELECT
            3'h0: begin

              case ((up_waddr - 7'h50) >> 3)

                2'd0:
                  if (up_wdata[2:0] <= 3'd4)
                    ao_source_sel[2:0] <= up_wdata[2:0];

                2'd1:
                  if (up_wdata[2:0] <= 3'd4)
                    ao_source_sel[5:3] <= up_wdata[2:0];

                2'd2:
                  if (up_wdata[2:0] <= 3'd4)
                    ao_source_sel[8:6] <= up_wdata[2:0];

                2'd3:
                  if (up_wdata[2:0] <= 3'd4)
                    ao_source_sel[11:9] <= up_wdata[2:0];

              endcase

            end


            // +0x04 MANUAL CODE
            3'h1: begin

              case ((up_waddr - 7'h50) >> 3)
                2'd0: ao_manual_code[15:0]  <= up_wdata[15:0];
                2'd1: ao_manual_code[31:16] <= up_wdata[15:0];
                2'd2: ao_manual_code[47:32] <= up_wdata[15:0];
                2'd3: ao_manual_code[63:48] <= up_wdata[15:0];
              endcase

            end


            // +0x08 GAIN
            3'h2: begin

              case ((up_waddr - 7'h50) >> 3)
                2'd0: ao_gain[31:0]   <= up_wdata;
                2'd1: ao_gain[63:32]  <= up_wdata;
                2'd2: ao_gain[95:64]  <= up_wdata;
                2'd3: ao_gain[127:96] <= up_wdata;
              endcase

            end


            // +0x0C OFFSET
            3'h3: begin

              case ((up_waddr - 7'h50) >> 3)
                2'd0: ao_offset[31:0]   <= up_wdata;
                2'd1: ao_offset[63:32]  <= up_wdata;
                2'd2: ao_offset[95:64]  <= up_wdata;
                2'd3: ao_offset[127:96] <= up_wdata;
              endcase

            end


            // +0x10 OUTPUT MIN
            3'h4: begin

              case ((up_waddr - 7'h50) >> 3)
                2'd0: ao_out_min[31:0]   <= up_wdata;
                2'd1: ao_out_min[63:32]  <= up_wdata;
                2'd2: ao_out_min[95:64]  <= up_wdata;
                2'd3: ao_out_min[127:96] <= up_wdata;
              endcase

            end


            // +0x14 OUTPUT MAX
            3'h5: begin

              case ((up_waddr - 7'h50) >> 3)
                2'd0: ao_out_max[31:0]   <= up_wdata;
                2'd1: ao_out_max[63:32]  <= up_wdata;
                2'd2: ao_out_max[95:64]  <= up_wdata;
                2'd3: ao_out_max[127:96] <= up_wdata;
              endcase

            end

            default: begin
            end

          endcase
        end


        up_wack <= 1'b1;

      end
    end
  end



  // =========================================================================
  // READ
  //
  // AXI-Lite is intentionally write-only at the application level.
  // Keep a valid read response for bus/protocol compatibility, but return zero.
  // Dynamic data are provided by the control-rate and raw IIO DMA paths.
  // =========================================================================

  always @(posedge up_clk) begin
    if (!up_rstn) begin
      up_rdata <= 32'd0;
      up_rack  <= 1'b0;
    end else begin
      up_rack <= 1'b0;
      if (up_rreq) begin
        up_rdata <= 32'd0;
        up_rack  <= 1'b1;
      end
    end
  end

endmodule
