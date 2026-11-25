`timescale 1ns / 1ps

module control_stream_serializer (
    input  wire         clk,
    input  wire         resetn,

    // One new control-loop sample. This should be asserted when
    // CORDIC0/1 phase outputs for the current averaged sample are valid.
    input  wire         frame_valid,

    // Averaged ADC values
    input  wire signed [31:0] avg0,
    input  wire signed [31:0] avg1,
    input  wire signed [31:0] avg2,
    input  wire signed [31:0] avg3,

    // Wrapped CORDIC phase values, signed32 BAM
    input  wire [63:0]  cordic_phase,

    // Final DAC codes
    input  wire [63:0]  ao_output,

    // 32-bit stream toward AXI-DMAC
    output reg  [31:0]  stream_data,
    output reg          stream_valid,
    output reg          stream_sync
);

    reg [2:0] word_index;
    reg       busy;

    // Latch one complete 32-byte control frame so that all eight DMA words
    // correspond to the same control-loop update.
    reg [31:0] avg0_latched;
    reg [31:0] avg1_latched;
    reg [31:0] avg2_latched;
    reg [31:0] avg3_latched;

    reg [31:0] phase0_latched;
    reg [31:0] phase1_latched;

    reg [15:0] ao0_latched;
    reg [15:0] ao1_latched;
    reg [15:0] ao2_latched;
    reg [15:0] ao3_latched;

    always @(posedge clk) begin
        if (!resetn) begin
            word_index   <= 3'd0;
            busy         <= 1'b0;

            stream_data  <= 32'd0;
            stream_valid <= 1'b0;
            stream_sync  <= 1'b0;

            avg0_latched <= 32'd0;
            avg1_latched <= 32'd0;
            avg2_latched <= 32'd0;
            avg3_latched <= 32'd0;

            phase0_latched <= 32'd0;
            phase1_latched <= 32'd0;

            ao0_latched  <= 16'd0;
            ao1_latched  <= 16'd0;
            ao2_latched  <= 16'd0;
            ao3_latched  <= 16'd0;

        end else begin
            // Default low; asserted only for active output cycles.
            stream_valid <= 1'b0;
            stream_sync  <= 1'b0;

            // Capture one complete control-loop frame.
            if (frame_valid && !busy) begin
                avg0_latched <= avg0;
                avg1_latched <= avg1;
                avg2_latched <= avg2;
                avg3_latched <= avg3;

                phase0_latched <= cordic_phase[31:0];
                phase1_latched <= cordic_phase[63:32];

                ao0_latched <= ao_output[15:0];
                ao1_latched <= ao_output[31:16];
                ao2_latched <= ao_output[47:32];
                ao3_latched <= ao_output[63:48];

                word_index <= 3'd0;
                busy       <= 1'b1;
            end

            // Serialize one 32-byte frame into eight 32-bit words.
            if (busy) begin
                stream_valid <= 1'b1;

                case (word_index)
                    3'd0: begin
                        stream_data <= avg0_latched;
                        stream_sync <= 1'b1;
                    end

                    3'd1: begin
                        stream_data <= avg1_latched;
                    end

                    3'd2: begin
                        stream_data <= avg2_latched;
                    end

                    3'd3: begin
                        stream_data <= avg3_latched;
                    end

                    3'd4: begin
                        stream_data <= phase0_latched;
                    end

                    3'd5: begin
                        stream_data <= phase1_latched;
                    end

                    3'd6: begin
                        stream_data <= {ao1_latched, ao0_latched};
                    end

                    3'd7: begin
                        stream_data <= {ao3_latched, ao2_latched};
                        busy        <= 1'b0;
                    end

                    default: begin
                        stream_data  <= 32'd0;
                        stream_valid <= 1'b0;
                        stream_sync  <= 1'b0;
                        busy         <= 1'b0;
                    end
                endcase

                if (word_index < 3'd7)
                    word_index <= word_index + 1'b1;
            end
        end
    end

endmodule
