module app_ctrl (

  // =========================================================================
  // Configuration outputs
  // =========================================================================

  output wire [5:0]   cordic_sel_x,
  output wire [5:0]   cordic_sel_y,

  output wire [3:0]   pid_enable,
  output wire [3:0]   pid_reset_toggle,
  output wire [7:0]   pid_input_sel,

  output wire [127:0] pid_input_center,
  output wire [127:0] pid_input_scale,
  output wire [127:0] pid_setpoint,

  output wire [127:0] pid_kp,
  output wire [127:0] pid_ki,
  output wire [127:0] pid_kd,

  output wire [127:0] pid_out_min,
  output wire [127:0] pid_out_max,

  output wire [11:0]  ao_source_sel,
  output wire [63:0]  ao_manual_code,

  output wire [127:0] ao_gain,
  output wire [127:0] ao_offset,
  output wire [127:0] ao_out_min,
  output wire [127:0] ao_out_max,

  output wire [15:0]  dac_code,
  output wire [3:0]   avg_shift,

  // One-way APPLY event into the ADC/control clock domain.
  output wire         apply_toggle,

  // =========================================================================
  // AXI-Lite
  // =========================================================================

  input  wire         s_axi_aclk,
  input  wire         s_axi_aresetn,

  input  wire         s_axi_awvalid,
  input  wire [8:0]   s_axi_awaddr,
  input  wire [2:0]   s_axi_awprot,
  output wire         s_axi_awready,

  input  wire         s_axi_wvalid,
  input  wire [31:0]  s_axi_wdata,
  input  wire [3:0]   s_axi_wstrb,
  output wire         s_axi_wready,

  output wire         s_axi_bvalid,
  output wire [1:0]   s_axi_bresp,
  input  wire         s_axi_bready,

  input  wire         s_axi_arvalid,
  input  wire [8:0]   s_axi_araddr,
  input  wire [2:0]   s_axi_arprot,
  output wire         s_axi_arready,

  output wire         s_axi_rvalid,
  output wire [31:0]  s_axi_rdata,
  output wire [1:0]   s_axi_rresp,
  input  wire         s_axi_rready
);

  wire         up_clk;
  wire         up_rstn;

  wire         up_wreq;
  wire [6:0]   up_waddr;
  wire [31:0]  up_wdata;
  wire         up_wack;

  wire         up_rreq;
  wire [6:0]   up_raddr;
  wire [31:0]  up_rdata;
  wire         up_rack;

  assign up_clk  = s_axi_aclk;
  assign up_rstn = s_axi_aresetn;

  app_ctrl_reg i_app_ctrl_reg (
    .up_rstn  (up_rstn),
    .up_clk   (up_clk),

    .up_wreq  (up_wreq),
    .up_waddr (up_waddr),
    .up_wdata (up_wdata),
    .up_wack  (up_wack),

    .up_rreq  (up_rreq),
    .up_raddr (up_raddr),
    .up_rdata (up_rdata),
    .up_rack  (up_rack),

    .cordic_sel_x (cordic_sel_x),
    .cordic_sel_y (cordic_sel_y),

    .pid_enable       (pid_enable),
    .pid_reset_toggle (pid_reset_toggle),
    .pid_input_sel    (pid_input_sel),
    .pid_input_center (pid_input_center),
    .pid_input_scale  (pid_input_scale),
    .pid_setpoint     (pid_setpoint),
    .pid_kp           (pid_kp),
    .pid_ki           (pid_ki),
    .pid_kd           (pid_kd),
    .pid_out_min      (pid_out_min),
    .pid_out_max      (pid_out_max),

    .ao_source_sel  (ao_source_sel),
    .ao_manual_code (ao_manual_code),
    .ao_gain        (ao_gain),
    .ao_offset      (ao_offset),
    .ao_out_min     (ao_out_min),
    .ao_out_max     (ao_out_max),

    .dac_code     (dac_code),
    .avg_shift    (avg_shift),
    .apply_toggle (apply_toggle)
  );

  up_axi #(
    .AXI_ADDRESS_WIDTH(9)
  ) i_up_axi (
    .up_rstn         (up_rstn),
    .up_clk          (up_clk),

    .up_axi_awvalid  (s_axi_awvalid),
    .up_axi_awaddr   (s_axi_awaddr),
    .up_axi_awready  (s_axi_awready),

    .up_axi_wvalid   (s_axi_wvalid),
    .up_axi_wdata    (s_axi_wdata),
    .up_axi_wstrb    (s_axi_wstrb),
    .up_axi_wready   (s_axi_wready),

    .up_axi_bvalid   (s_axi_bvalid),
    .up_axi_bresp    (s_axi_bresp),
    .up_axi_bready   (s_axi_bready),

    .up_axi_arvalid  (s_axi_arvalid),
    .up_axi_araddr   (s_axi_araddr),
    .up_axi_arready  (s_axi_arready),

    .up_axi_rvalid   (s_axi_rvalid),
    .up_axi_rresp    (s_axi_rresp),
    .up_axi_rdata    (s_axi_rdata),
    .up_axi_rready   (s_axi_rready),

    .up_wreq         (up_wreq),
    .up_waddr        (up_waddr),
    .up_wdata        (up_wdata),
    .up_wack         (up_wack),

    .up_rreq         (up_rreq),
    .up_raddr        (up_raddr),
    .up_rdata        (up_rdata),
    .up_rack         (up_rack)
  );

endmodule
