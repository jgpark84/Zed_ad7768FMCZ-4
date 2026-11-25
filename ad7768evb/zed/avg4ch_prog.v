module avg4ch_prog (
  input  wire               clk,
  input  wire               valid,

  input  wire [3:0]         avg_shift,

  input  wire signed [31:0] data0,
  input  wire signed [31:0] data1,
  input  wire signed [31:0] data2,
  input  wire signed [31:0] data3,

  output reg signed [31:0]  avg0 = 32'd0,
  output reg signed [31:0]  avg1 = 32'd0,
  output reg signed [31:0]  avg2 = 32'd0,
  output reg signed [31:0]  avg3 = 32'd0,

  output reg                avg_valid = 1'b0
);

  reg signed [39:0] acc0 = 40'd0;
  reg signed [39:0] acc1 = 40'd0;
  reg signed [39:0] acc2 = 40'd0;
  reg signed [39:0] acc3 = 40'd0;

  reg [10:0] count = 11'd0;

  wire [10:0] window_size =
    (avg_shift <= 4'd10) ? (11'd1 << avg_shift) : 11'd1024;

  always @(posedge clk) begin
    avg_valid <= 1'b0;

    if (valid) begin
      if (count == window_size - 1'b1) begin

        avg0 <= ($signed(acc0) + $signed(data0)) >>> avg_shift;
        avg1 <= ($signed(acc1) + $signed(data1)) >>> avg_shift;
        avg2 <= ($signed(acc2) + $signed(data2)) >>> avg_shift;
        avg3 <= ($signed(acc3) + $signed(data3)) >>> avg_shift;

        acc0 <= 40'd0;
        acc1 <= 40'd0;
        acc2 <= 40'd0;
        acc3 <= 40'd0;

        count <= 11'd0;
        avg_valid <= 1'b1;

      end else begin

        acc0 <= acc0 + $signed(data0);
        acc1 <= acc1 + $signed(data1);
        acc2 <= acc2 + $signed(data2);
        acc3 <= acc3 + $signed(data3);

        count <= count + 1'b1;

      end
    end
  end

endmodule