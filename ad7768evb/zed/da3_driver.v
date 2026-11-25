module da3_driver ( 
  input  wire clk, 
  input  wire rst,
  input  wire [15:0] dac_code,

  output reg  sclk = 1'b0, 
  output reg  sdin = 1'b1, 
  output reg  sync = 1'b1, 
  output reg  ldac = 1'b0 
); 
 
  reg [15:0] shift_reg = 16'h8000; 
  reg [4:0]  bit_cnt   = 5'd0; 
  reg [5:0]  div_cnt   = 6'd0; 
 
  localparam DIV = 32;
 
  always @(posedge clk) begin 
    if (rst) begin 
      sclk      <= 1'b0; 
      sdin      <= 1'b1; 
      sync      <= 1'b1; 
      ldac      <= 1'b0; 
      shift_reg <= 16'h8000; 
      bit_cnt   <= 5'd0; 
      div_cnt   <= 6'd0; 
    end else begin 
 
      ldac <= 1'b0; 
 
      if (sync) begin 
        sync      <= 1'b0; 
        sclk      <= 1'b0; 
        shift_reg <= dac_code; 
        bit_cnt   <= 5'd0; 
        div_cnt   <= 6'd0; 
        sdin      <= dac_code[15];
      end else begin 
 
        if (div_cnt == DIV-1) begin 
          div_cnt <= 6'd0; 
 
          if (sclk == 1'b0) begin 
            sclk <= 1'b1; 
          end else begin 
            sclk <= 1'b0; 
 
            if (bit_cnt == 5'd15) begin 
              sync    <= 1'b1; 
              bit_cnt <= 5'd0; 
            end else begin 
              bit_cnt   <= bit_cnt + 1'b1; 
              shift_reg <= {shift_reg[14:0], 1'b0}; 
              sdin      <= shift_reg[14]; 
            end 
          end 
 
        end else begin 
          div_cnt <= div_cnt + 1'b1; 
        end 
      end 
    end 
  end 
 
endmodule