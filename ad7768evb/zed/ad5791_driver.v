`timescale 1ns / 1ps
// AD5791 / EVAL-CN0531-PMDZ: standalone 20-bit DAC SPI transmitter.
//
// Timing approach is based on the existing da3_driver.v:
//   - One system-clock domain; registered GPIO outputs only.
//   - Counter-divided SPI clock, with SDIN stable around capture edges.
//   - A new input code is latched at the start of each 24-bit frame.
//
// AD5791-specific differences:
//   - SCLK idles HIGH. The AD5791 captures SDIN on each FALLING edge.
//   - Exactly 24 falling edges per /SYNC-low frame.
//   - SDIN changes only on RISING edges (the opposite, non-capture edge).
//   - /LDAC pulses after /SYNC rises to apply the 20-bit DAC register.
//   - Startup: DAC midcode -> LDAC -> CTRL=0x00012 -> normal operation.
//     Latching midcode BEFORE releasing the output clamp prevents an
//     unwanted full-scale excursion during initialization.
//   - Latest-value semantics: if dac_code changes mid-frame, the latest
//     code will be transmitted after the current frame completes.
//
// This module alone does not assign Pmod pins and does not create a CDC.
// dac_code must be synchronous to clk (or transferred safely to this clock).
//
// Default assumes a 100 MHz input clock (the existing DA3 path's FCLK_CLK0).
// SPI_HALF_CYCLES=5 => 10 MHz SCLK; 24 bits take ~2.4 us. This supports
// faster AO updates than the original DA3's DIV=32, ~1.56 MHz SCLK.
// For a DA3-like bring-up SPI speed at 100 MHz, set SPI_HALF_CYCLES=32.
// Parameters express timing in input-clock cycles. Do NOT blindly reuse
// defaults if clk is changed (e.g., to 50 MHz).
module ad5791_driver #(
    parameter integer SPI_HALF_CYCLES  = 5,        // >= 2 at 100 MHz
    parameter integer STARTUP_CYCLES   = 1000000,  // 10 ms at 100 MHz
    parameter integer RESET_WAIT_CYCLES = 16,       // 160 ns at 100 MHz
    parameter integer CS_HIGH_CYCLES   = 5,        // >= 50 ns at 100 MHz
    parameter integer LDAC_LOW_CYCLES  = 5         // >= 50 ns at 100 MHz
)(
    input  wire        clk,
    input  wire        rst,       // active-high synchronous reset, optional
    input  wire [19:0] dac_code,  // offset binary: 0x80000 ~ 0 V in +/-5 V mode
    output reg         sclk    = 1'b1,
    output reg         sdin    = 1'b0,
    output reg         sync_n  = 1'b1,
    output reg         ldac_n  = 1'b1,
    output reg         reset_n = 1'b0,
    output reg         clr_n   = 1'b1,
    output reg         ready   = 1'b0,
    output wire        busy
);
    // AD5791 24-bit frame: {R/W=0, register address[2:0], data[19:0]}.
    // DAC register address 1, control register address 2.
    localparam [23:0] FRAME_MID  = 24'h180000; // DAC=0x80000
    localparam [23:0] FRAME_CTRL = 24'h200012; // RBUF=1, BIN/2sC=1, normal output

    localparam [3:0]
        ST_STARTUP   = 4'd0,
        ST_RESETWAIT = 4'd1,
        ST_IDLE      = 4'd2,
        ST_ASSERT    = 4'd3,
        ST_FALL      = 4'd4,
        ST_RISE      = 4'd5,
        ST_DEASSERT  = 4'd6,
        ST_CS_GAP    = 4'd7,
        ST_LDAC      = 4'd8;

    localparam [1:0]
        FRAME_KIND_MID  = 2'd0,
        FRAME_KIND_CTRL = 2'd1,
        FRAME_KIND_DATA = 2'd2;

    // Explicit initial values, as in da3_driver.v: deterministic FPGA
    // configuration startup even if rst is tied inactive in the top level.
    reg [3:0]  state        = ST_STARTUP;
    reg [31:0] wait_count   = 32'd0;
    reg [31:0] half_count   = 32'd0;
    reg [4:0]  bit_count    = 5'd0;
    reg [23:0] shift_reg    = 24'd0;
    reg [19:0] sending_code = 20'h80000;
    reg [19:0] last_sent    = 20'h80000;
    reg [1:0]  init_step    = 2'd0; // 0: mid; 1: control; 2: operational
    reg [1:0]  frame_kind   = FRAME_KIND_MID;

    assign busy = (state != ST_IDLE) || !ready;

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_STARTUP;
            wait_count   <= 32'd0;
            half_count   <= 32'd0;
            bit_count    <= 5'd0;
            shift_reg    <= 24'd0;
            sending_code <= 20'h80000;
            last_sent    <= 20'h80000;
            init_step    <= 2'd0;
            frame_kind   <= FRAME_KIND_MID;
            sclk         <= 1'b1;
            sdin         <= 1'b0;
            sync_n       <= 1'b1;
            ldac_n       <= 1'b1;
            reset_n      <= 1'b0;
            clr_n        <= 1'b1;
            ready        <= 1'b0;
        end else begin
            case (state)
                ST_STARTUP: begin
                    // Keep DAC in hardware reset while analog rails settle.
                    reset_n <= 1'b0;
                    clr_n   <= 1'b1;
                    sync_n  <= 1'b1;
                    sclk    <= 1'b1;
                    ldac_n  <= 1'b1;
                    ready   <= 1'b0;
                    if (wait_count == STARTUP_CYCLES - 1) begin
                        wait_count <= 32'd0;
                        reset_n    <= 1'b1;
                        state      <= ST_RESETWAIT;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_RESETWAIT: begin
                    if (wait_count == RESET_WAIT_CYCLES - 1) begin
                        wait_count <= 32'd0;
                        state      <= ST_IDLE;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_IDLE: begin
                    sclk   <= 1'b1;
                    sync_n <= 1'b1;
                    if (init_step == 2'd0) begin
                        // Load safe midcode while the output is still clamped.
                        frame_kind <= FRAME_KIND_MID;
                        shift_reg  <= FRAME_MID;
                        sdin       <= FRAME_MID[23];
                        bit_count  <= 5'd0;
                        half_count <= 32'd0;
                        state      <= ST_ASSERT;
                    end else if (init_step == 2'd1) begin
                        // Enable normal bipolar output AFTER midcode is latched.
                        frame_kind <= FRAME_KIND_CTRL;
                        shift_reg  <= FRAME_CTRL;
                        sdin       <= FRAME_CTRL[23];
                        bit_count  <= 5'd0;
                        half_count <= 32'd0;
                        state      <= ST_ASSERT;
                    end else if (dac_code != last_sent) begin
                        // Coherent snapshot of current desired output code.
                        frame_kind   <= FRAME_KIND_DATA;
                        shift_reg    <= {4'h1, dac_code};
                        sending_code <= dac_code;
                        sdin         <= 1'b0; // frame[23]
                        bit_count    <= 5'd0;
                        half_count   <= 32'd0;
                        state        <= ST_ASSERT;
                    end
                end

                ST_ASSERT: begin
                    // SCLK high and first data bit already stable.
                    sync_n     <= 1'b0;
                    half_count <= 32'd0;
                    state      <= ST_FALL;
                end

                ST_FALL: begin
                    if (half_count == SPI_HALF_CYCLES - 1) begin
                        half_count <= 32'd0;
                        sclk       <= 1'b0; // AD5791 samples SDIN here.
                        state      <= ST_RISE;
                    end else begin
                        half_count <= half_count + 1'b1;
                    end
                end

                ST_RISE: begin
                    if (half_count == SPI_HALF_CYCLES - 1) begin
                        half_count <= 32'd0;
                        sclk       <= 1'b1;
                        if (bit_count == 5'd23) begin
                            state <= ST_DEASSERT;
                        end else begin
                            // Change SDIN ONLY at rising edge, leaving one
                            // full half-SCLK period before next capture.
                            sdin      <= shift_reg[22];
                            shift_reg <= {shift_reg[22:0], 1'b0};
                            bit_count <= bit_count + 1'b1;
                            state     <= ST_FALL;
                        end
                    end else begin
                        half_count <= half_count + 1'b1;
                    end
                end

                ST_DEASSERT: begin
                    // Hold SCLK high and terminate the exact 24-edge frame.
                    sync_n     <= 1'b1;
                    wait_count <= 32'd0;
                    state      <= ST_CS_GAP;
                end

                ST_CS_GAP: begin
                    if (wait_count == CS_HIGH_CYCLES - 1) begin
                        wait_count <= 32'd0;
                        if (frame_kind == FRAME_KIND_CTRL) begin
                            // Control word is latched at /SYNC rising edge.
                            init_step <= 2'd2;
                            ready     <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            // Asynchronous DAC update only while /SYNC=high.
                            ldac_n <= 1'b0;
                            state  <= ST_LDAC;
                        end
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_LDAC: begin
                    if (wait_count == LDAC_LOW_CYCLES - 1) begin
                        ldac_n     <= 1'b1;
                        wait_count <= 32'd0;
                        if (frame_kind == FRAME_KIND_MID) begin
                            init_step <= 2'd1;
                        end else if (frame_kind == FRAME_KIND_DATA) begin
                            last_sent <= sending_code;
                        end
                        state <= ST_IDLE;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                default: begin
                    state   <= ST_STARTUP;
                    ready   <= 1'b0;
                    sync_n  <= 1'b1;
                    ldac_n  <= 1'b1;
                    reset_n <= 1'b0;
                end
            endcase
        end
    end
endmodule
