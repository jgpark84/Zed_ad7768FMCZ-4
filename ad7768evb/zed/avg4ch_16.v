module avg4ch_16 (
  input  wire               clk,
  input  wire               valid,

  input  wire signed [31:0]  data0,
  input  wire signed [31:0]  data1,
  input  wire signed [31:0]  data2,
  input  wire signed [31:0]  data3,

  output reg signed [31:0]   avg0 = 32'd0,
  output reg signed [31:0]   avg1 = 32'd0,
  output reg signed [31:0]   avg2 = 32'd0,
  output reg signed [31:0]   avg3 = 32'd0
);

  reg signed [31:0] acc0 = 32'd0;
  reg signed [31:0] acc1 = 32'd0;
  reg signed [31:0] acc2 = 32'd0;
  reg signed [31:0] acc3 = 32'd0;

  reg [3:0] count = 4'd0;

  always @(posedge clk) begin
    if (valid) begin
      if (count == 4'd15) begin
        avg0 <= (acc0 + data0) >>> 4;
        avg1 <= (acc1 + data1) >>> 4;
        avg2 <= (acc2 + data2) >>> 4;
        avg3 <= (acc3 + data3) >>> 4;

        acc0 <= 32'd0;
        acc1 <= 32'd0;
        acc2 <= 32'd0;
        acc3 <= 32'd0;

        count <= 4'd0;
      end else begin
        acc0 <= acc0 + data0;
        acc1 <= acc1 + data1;
        acc2 <= acc2 + data2;
        acc3 <= acc3 + data3;

        count <= count + 1'b1;
      end
    end
  end

endmodule