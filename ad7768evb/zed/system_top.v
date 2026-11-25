// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2019-2024 Analog Devices, Inc. All rights reserved.
//
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module system_top (

  inout       [14:0]      ddr_addr,
  inout       [ 2:0]      ddr_ba,
  inout                   ddr_cas_n,
  inout                   ddr_ck_n,
  inout                   ddr_ck_p,
  inout                   ddr_cke,
  inout                   ddr_cs_n,
  inout       [ 3:0]      ddr_dm,
  inout       [31:0]      ddr_dq,
  inout       [ 3:0]      ddr_dqs_n,
  inout       [ 3:0]      ddr_dqs_p,
  inout                   ddr_odt,
  inout                   ddr_ras_n,
  inout                   ddr_reset_n,
  inout                   ddr_we_n,

  inout                   fixed_io_ddr_vrn,
  inout                   fixed_io_ddr_vrp,
  inout       [53:0]      fixed_io_mio,
  inout                   fixed_io_ps_clk,
  inout                   fixed_io_ps_porb,
  inout                   fixed_io_ps_srstb,

  inout       [31:0]      gpio_bd,

  output                  hdmi_out_clk,
  output                  hdmi_vsync,
  output                  hdmi_hsync,
  output                  hdmi_data_e,
  output      [15:0]      hdmi_data,

  output                  i2s_mclk,
  output                  i2s_bclk,
  output                  i2s_lrclk,
  output                  i2s_sdata_out,
  input                   i2s_sdata_in,

  output                  spdif,

  inout                   iic_scl,
  inout                   iic_sda,
  inout       [ 1:0]      iic_mux_scl,
  inout       [ 1:0]      iic_mux_sda,

  input                   otg_vbusoc,

  input                   clk_in,
  input                   ready_in,
  input       [ 7:0]      data_in,

  output                  spi_csn,
  output                  spi_clk,
  output                  spi_mosi,
  input                   spi_miso,

  inout                   gpio_0_mode_0,
  inout                   gpio_1_mode_1,
  inout                   gpio_2_mode_2,
  inout                   gpio_3_mode_3,

  output                  gpio_4_filter,
  output                  reset_n,
  output                  start_n,
  output                  mclk,

  // Physical DAC outputs
  // AO0 -> JA upper row, AO1 -> JA lower row
  // AO2 -> JB upper row, AO3 -> JB lower row
  output                  da3_sclk,
  output                  da3_sdin,
  output                  da3_sync,
  output                  da3_ldac,

  output                  da3_1_sclk,
  output                  da3_1_sdin,
  output                  da3_1_sync,
  output                  da3_1_ldac,

  output                  da3_2_sclk,
  output                  da3_2_sdin,
  output                  da3_2_sync,
  output                  da3_2_ldac,

  output                  da3_3_sclk,
  output                  da3_3_sdin,
  output                  da3_3_sync,
  output                  da3_3_ldac,

  // New AD5791 / CN0531 physical outputs: JC = AO4, JD = AO5.
  // Pin assignments will be added in system_constr.xdc in a later step.
  output                  cn0531_jc_sclk,
  output                  cn0531_jc_sdin,
  output                  cn0531_jc_sync_n,
  output                  cn0531_jc_ldac_n,
  output                  cn0531_jc_reset_n,
  output                  cn0531_jc_clr_n,

  output                  cn0531_jd_sclk,
  output                  cn0531_jd_sdin,
  output                  cn0531_jd_sync_n,
  output                  cn0531_jd_ldac_n,
  output                  cn0531_jd_reset_n,
  output                  cn0531_jd_clr_n
);


  // =========================================================================
  // Original / ADI internal signals
  // =========================================================================

  wire            adc_clk;
  wire            adc_valid;
  wire            adc_valid_pp;
  wire            adc_sync;
  wire    [31:0]  adc_data;

  wire    [31:0]  adc_data_0;
  wire    [31:0]  adc_data_1;
  wire    [31:0]  adc_data_2;
  wire    [31:0]  adc_data_3;

  wire    [31:0]  adc_data_4;
  wire    [31:0]  adc_data_5;
  wire    [31:0]  adc_data_6;
  wire    [31:0]  adc_data_7;

  wire    [63:0]  adc_gpio_i;
  wire    [63:0]  adc_gpio_o;
  wire    [63:0]  adc_gpio_t;

  wire    [63:0]  gpio_i;
  wire    [63:0]  gpio_o;
  wire    [63:0]  gpio_t;

  wire    [ 1:0]  iic_mux_scl_i_s;
  wire    [ 1:0]  iic_mux_scl_o_s;
  wire            iic_mux_scl_t_s;

  wire    [ 1:0]  iic_mux_sda_i_s;
  wire    [ 1:0]  iic_mux_sda_o_s;
  wire            iic_mux_sda_t_s;

  wire            da3_rst;
  wire            da3_clk;
  wire            adc_test_clk;

  wire    [31:0]  gpio_bd_o_mux;
  wire    [31:0]  gpio_bd_t_mux;


  // =========================================================================
  // ADC sign extension
  //
  // AD7768 actual ADC sample = [23:0]
  // =========================================================================

  wire signed [31:0] adc0_s =
    {{8{adc_data_0[23]}}, adc_data_0[23:0]};

  wire signed [31:0] adc1_s =
    {{8{adc_data_1[23]}}, adc_data_1[23:0]};

  wire signed [31:0] adc2_s =
    {{8{adc_data_2[23]}}, adc_data_2[23:0]};

  wire signed [31:0] adc3_s =
    {{8{adc_data_3[23]}}, adc_data_3[23:0]};


  // =========================================================================
  // Common AXI configuration
  // =========================================================================

  wire [15:0] dac_code;

  // AXI-domain shadow configuration exported by app_ctrl
  wire [3:0]  avg_shift_shadow;

  // ADC-domain local configuration actually used by realtime logic
  reg [3:0] avg_shift = 4'd4;


  // =========================================================================
  // Averager
  // =========================================================================

  wire signed [31:0] avg0;
  wire signed [31:0] avg1;
  wire signed [31:0] avg2;
  wire signed [31:0] avg3;

  wire               avg_valid;


  // =========================================================================
  // CORDIC packed interface
  // =========================================================================

  wire [5:0]   cordic_sel_x_shadow;
  wire [5:0]   cordic_sel_y_shadow;

  reg [5:0] cordic_sel_x = {2'd0, 2'd2, 2'd0};
  reg [5:0] cordic_sel_y = {2'd1, 2'd3, 2'd1};

  wire [95:0]  cordic_phase;
  wire [31:0]  cordic_status;

  wire signed [31:0] cordic_x [0:2];
  wire signed [31:0] cordic_y [0:2];

  wire [2:0] cordic_in_valid;
  wire [2:0] cordic_out_valid;
  wire [2:0] cordic_busy;


  // =========================================================================
  // PID packed interface
  // =========================================================================

  wire [3:0]   pid_enable_shadow;
  wire [3:0]   pid_reset_toggle;

  wire [7:0]   pid_input_sel_shadow;

  wire [127:0] pid_input_center_shadow;
  wire [127:0] pid_input_scale_shadow;
  wire [127:0] pid_setpoint_shadow;

  wire [127:0] pid_kp_shadow;
  wire [127:0] pid_ki_shadow;
  wire [127:0] pid_kd_shadow;

  wire [127:0] pid_out_min_shadow;
  wire [127:0] pid_out_max_shadow;

  reg [3:0] pid_enable = 4'd0;
  reg [7:0] pid_input_sel = {2'd1, 2'd0, 2'd1, 2'd0};
  reg [127:0] pid_input_center = 128'd0;
  reg [127:0] pid_input_scale = {4{32'h00010000}};
  reg [127:0] pid_setpoint = 128'd0;
  reg [127:0] pid_kp = 128'd0;
  reg [127:0] pid_ki = 128'd0;
  reg [127:0] pid_kd = 128'd0;
  reg [127:0] pid_out_min = {4{32'h80000000}};
  reg [127:0] pid_out_max = {4{32'h7FFFFFFF}};

  wire [127:0] pid_output;
  wire [127:0] pid_error;
  wire [127:0] pid_integrator;
  wire [127:0] pid_status;

  wire signed [31:0] pid_input [0:3];
  wire [3:0]         pid_update;

  // General-input frontend: source selection -> normalization -> signed32 PID input
  wire signed [31:0] normalizer_source [0:1];
  wire signed [31:0] normalizer_output [0:1];
  wire [1:0]         normalizer_valid;


  // =========================================================================
  // Configuration APPLY CDC
  //
  // AXI shadow bank -> APPLY toggle -> ADC-domain local configuration bank.
  // There is intentionally no PL->AXI readback CDC. Dynamic data are read via
  // DMA; software already owns the configuration values it writes.
  // =========================================================================

  wire apply_toggle;

  (* ASYNC_REG = "TRUE" *) reg apply_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) reg apply_sync2 = 1'b0;
  reg apply_sync2_d = 1'b0;

  wire apply_pulse_adc = apply_sync2 ^ apply_sync2_d;

  always @(posedge adc_test_clk) begin
    apply_sync1   <= apply_toggle;
    apply_sync2   <= apply_sync1;
    apply_sync2_d <= apply_sync2;

    if (apply_pulse_adc) begin
      avg_shift <= avg_shift_shadow;

      cordic_sel_x <= cordic_sel_x_shadow;
      cordic_sel_y <= cordic_sel_y_shadow;

      pid_enable       <= pid_enable_shadow;
      pid_input_sel    <= pid_input_sel_shadow;
      pid_input_center <= pid_input_center_shadow;
      pid_input_scale  <= pid_input_scale_shadow;
      pid_setpoint     <= pid_setpoint_shadow;
      pid_kp           <= pid_kp_shadow;
      pid_ki           <= pid_ki_shadow;
      pid_kd           <= pid_kd_shadow;
      pid_out_min      <= pid_out_min_shadow;
      pid_out_max      <= pid_out_max_shadow;

      ao_source_sel  <= ao_source_sel_shadow;
      ao_manual_code <= ao_manual_code_shadow;
      ao_gain        <= ao_gain_shadow;
      ao_offset      <= ao_offset_shadow;
      ao_out_min     <= ao_out_min_shadow;
      ao_out_max     <= ao_out_max_shadow;

      // AO4/AO5 shadow -> ADC-clock local config, same APPLY event.
      ao20_source_sel  <= ao20_source_sel_shadow;
      ao20_manual_code <= ao20_manual_code_shadow;
      ao20_gain        <= ao20_gain_shadow;
      ao20_offset      <= ao20_offset_shadow;
      ao20_out_min     <= ao20_out_min_shadow;
      ao20_out_max     <= ao20_out_max_shadow;
    end
  end


  // =========================================================================
  // PID reset CDC
  //
  // AXI/up_clk domain:
  //   pid_reset_toggle changes state on every reset command
  //
  // ADC domain:
  //   synchronize toggle through 2 FFs, then edge-detect with XOR
  // =========================================================================

  (* ASYNC_REG = "TRUE" *) reg [3:0] pid_reset_sync1 = 4'd0;
  (* ASYNC_REG = "TRUE" *) reg [3:0] pid_reset_sync2 = 4'd0;
  reg [3:0] pid_reset_sync2_d = 4'd0;

  wire [3:0] pid_reset_pulse_adc;

  always @(posedge adc_test_clk) begin
    pid_reset_sync1   <= pid_reset_toggle;
    pid_reset_sync2   <= pid_reset_sync1;
    pid_reset_sync2_d <= pid_reset_sync2;
  end

  assign pid_reset_pulse_adc =
    pid_reset_sync2 ^ pid_reset_sync2_d;


  // =========================================================================
  // AO packed interface
  // =========================================================================

  wire [11:0]  ao_source_sel_shadow;
  wire [63:0]  ao_manual_code_shadow;

  wire [127:0] ao_gain_shadow;
  wire [127:0] ao_offset_shadow;
  wire [127:0] ao_out_min_shadow;
  wire [127:0] ao_out_max_shadow;

  reg [11:0] ao_source_sel = 12'd0;
  reg [63:0] ao_manual_code = {4{16'h8000}};
  reg [127:0] ao_gain = {4{32'h00010000}};
  reg [127:0] ao_offset = 128'd0;
  reg [127:0] ao_out_min = 128'd0;
  reg [127:0] ao_out_max = {4{32'h0000FFFF}};

  wire [63:0]  ao_output;
  wire [127:0] ao_status;

  wire signed [31:0] ao_source [0:3];

  // =========================================================================
  // Two independent 20-bit AO channels (JC/JD), shadow + ADC local registers
  // =========================================================================
  wire [5:0]  ao20_source_sel_shadow;
  wire [39:0] ao20_manual_code_shadow;
  wire [63:0] ao20_gain_shadow;
  wire [63:0] ao20_offset_shadow;
  wire [63:0] ao20_out_min_shadow;
  wire [63:0] ao20_out_max_shadow;

  reg [5:0]  ao20_source_sel = 6'd0;
  reg [39:0] ao20_manual_code = {2{20'h80000}};
  reg [63:0] ao20_gain = {2{32'h00010000}};
  reg [63:0] ao20_offset = 64'd0;
  reg [63:0] ao20_out_min = 64'd0;
  reg [63:0] ao20_out_max = {2{32'h000FFFFF}};

  wire [39:0] ao20_output;
  wire [63:0] ao20_status;
  wire signed [31:0] ao20_source [0:1];


  // =========================================================================
  // Basic assignments
  // =========================================================================

  assign mclk          = 1'b0;
  assign start_n       = 1'b1;
  assign gpio_4_filter = 1'b1;
  assign reset_n       = gpio_o[32];

  assign da3_rst = 1'b0;


  // =========================================================================
  // 4-to-1 selector function
  // =========================================================================

  function signed [31:0] select4;

    input [1:0] sel;

    input signed [31:0] d0;
    input signed [31:0] d1;
    input signed [31:0] d2;
    input signed [31:0] d3;

    begin

      case (sel)

        2'd0:
          select4 = d0;

        2'd1:
          select4 = d1;

        2'd2:
          select4 = d2;

        default:
          select4 = d3;

      endcase

    end
  endfunction


  // =========================================================================
  // I/O buffers
  // =========================================================================

  ad_iobuf #(
    .DATA_WIDTH(4)
  ) i_iobuf (
    .dio_t (gpio_t[51:48]),
    .dio_i (gpio_o[51:48]),
    .dio_o (gpio_i[51:48]),
    .dio_p ({
      gpio_3_mode_3,
      gpio_2_mode_2,
      gpio_1_mode_1,
      gpio_0_mode_0
    })
  );


  // Clock-debug LED overrides removed.
  // Restore the original GPIO bus behavior.
  assign gpio_bd_o_mux = gpio_o[31:0];
  assign gpio_bd_t_mux = gpio_t[31:0];


  ad_iobuf #(
    .DATA_WIDTH(32)
  ) i_iobuf_bd (
    .dio_t (gpio_bd_t_mux),
    .dio_i (gpio_bd_o_mux),
    .dio_o (gpio_i[31:0]),
    .dio_p (gpio_bd)
  );


  assign gpio_i[32]    = 2'b0;
  assign gpio_i[47:33] = gpio_o[47:33];
  assign gpio_i[63:52] = gpio_o[63:52];


  ad_iobuf #(
    .DATA_WIDTH(2)
  ) i_iic_mux_scl (
    .dio_t ({iic_mux_scl_t_s, iic_mux_scl_t_s}),
    .dio_i (iic_mux_scl_o_s),
    .dio_o (iic_mux_scl_i_s),
    .dio_p (iic_mux_scl)
  );


  ad_iobuf #(
    .DATA_WIDTH(2)
  ) i_iic_mux_sda (
    .dio_t ({iic_mux_sda_t_s, iic_mux_sda_t_s}),
    .dio_i (iic_mux_sda_o_s),
    .dio_o (iic_mux_sda_i_s),
    .dio_p (iic_mux_sda)
  );


  // =========================================================================
  // Programmable 4-channel averaging
  // =========================================================================

  avg4ch_prog i_avg4ch_prog (

    .clk       (adc_test_clk),
    .valid     (adc_valid),

    .avg_shift (avg_shift),

    .data0     (adc0_s),
    .data1     (adc1_s),
    .data2     (adc2_s),
    .data3     (adc3_s),

    .avg0      (avg0),
    .avg1      (avg1),
    .avg2      (avg2),
    .avg3      (avg3),

    .avg_valid (avg_valid)
  );


  // =========================================================================
  // CORDIC selectors
  //
  // CORDIC0 / CORDIC1:
  //   averaged ADC channels
  //
  // CORDIC2:
  //   raw ADC channels
  // =========================================================================

  assign cordic_x[0] =
    select4(
      cordic_sel_x[1:0],
      avg0,
      avg1,
      avg2,
      avg3
    );

  assign cordic_y[0] =
    select4(
      cordic_sel_y[1:0],
      avg0,
      avg1,
      avg2,
      avg3
    );


  assign cordic_x[1] =
    select4(
      cordic_sel_x[3:2],
      avg0,
      avg1,
      avg2,
      avg3
    );

  assign cordic_y[1] =
    select4(
      cordic_sel_y[3:2],
      avg0,
      avg1,
      avg2,
      avg3
    );


  assign cordic_x[2] =
    select4(
      cordic_sel_x[5:4],
      adc0_s,
      adc1_s,
      adc2_s,
      adc3_s
    );

  assign cordic_y[2] =
    select4(
      cordic_sel_y[5:4],
      adc0_s,
      adc1_s,
      adc2_s,
      adc3_s
    );


  assign cordic_in_valid[0] = avg_valid;
  assign cordic_in_valid[1] = avg_valid;
  assign cordic_in_valid[2] = adc_valid;


  // =========================================================================
  // 3 x CORDIC
  // =========================================================================

  genvar c;

  generate

    for (c = 0; c < 3; c = c + 1) begin : GEN_CORDIC

      cordic_atan2 i_cordic (

        .clk       (adc_test_clk),
        .rst       (1'b0),

        .in_valid  (cordic_in_valid[c]),

        .x_in      (cordic_x[c]),
        .y_in      (cordic_y[c]),

        .phase     (cordic_phase[c*32 +: 32]),

        .out_valid (cordic_out_valid[c]),
        .busy      (cordic_busy[c])
      );

    end

  endgenerate


  assign cordic_status = {
    26'd0,
    cordic_busy,
    cordic_out_valid
  };


  // =========================================================================
  // PID input routing
  //
  // PID0 / PID1 = phase PID
  //
  // selector:
  //   0 = CORDIC0
  //   1 = CORDIC1
  //   2 = CORDIC2
  //   3 = zero
  //
  // PID2 / PID3 = general PID
  //
  // selector:
  //   0 = avg0
  //   1 = avg1
  //   2 = avg2
  //   3 = avg3
  // =========================================================================

  assign pid_input[0] =
    (pid_input_sel[1:0] == 2'd0) ?
      cordic_phase[31:0] :

    (pid_input_sel[1:0] == 2'd1) ?
      cordic_phase[63:32] :

    (pid_input_sel[1:0] == 2'd2) ?
      cordic_phase[95:64] :

      32'sd0;


  assign pid_input[1] =
    (pid_input_sel[3:2] == 2'd0) ?
      cordic_phase[31:0] :

    (pid_input_sel[3:2] == 2'd1) ?
      cordic_phase[63:32] :

    (pid_input_sel[3:2] == 2'd2) ?
      cordic_phase[95:64] :

      32'sd0;


  assign normalizer_source[0] =
    select4(
      pid_input_sel[5:4],
      avg0,
      avg1,
      avg2,
      avg3
    );


  assign normalizer_source[1] =
    select4(
      pid_input_sel[7:6],
      avg0,
      avg1,
      avg2,
      avg3
    );


  assign pid_input[2] = normalizer_output[0];
  assign pid_input[3] = normalizer_output[1];


  // =========================================================================
  // PID update strobes
  // =========================================================================

  assign pid_update[0] =
    (pid_input_sel[1:0] == 2'd0) ?
      cordic_out_valid[0] :

    (pid_input_sel[1:0] == 2'd1) ?
      cordic_out_valid[1] :

    (pid_input_sel[1:0] == 2'd2) ?
      cordic_out_valid[2] :

      1'b0;


  assign pid_update[1] =
    (pid_input_sel[3:2] == 2'd0) ?
      cordic_out_valid[0] :

    (pid_input_sel[3:2] == 2'd1) ?
      cordic_out_valid[1] :

    (pid_input_sel[3:2] == 2'd2) ?
      cordic_out_valid[2] :

      1'b0;


  assign pid_update[2] = normalizer_valid[0];
  assign pid_update[3] = normalizer_valid[1];


  // =========================================================================
  // 2 x general-input normalizer
  //
  // Software calculates center and scale and writes them through AXI.
  // The realtime path only applies the fixed transform:
  //
  //   normalized = (source - center) * scale / 2^16
  //
  // scale is Q16.16. The output is saturated signed32.
  // PID0/PID1 do not use this block because CORDIC already produces signed32.
  // =========================================================================

  genvar n;

  generate

    for (n = 0; n < 2; n = n + 1) begin : GEN_NORMALIZER

      input_normalizer i_input_normalizer (
        .clk             (adc_test_clk),
        .rst             (1'b0),
        .in_valid        (avg_valid),

        .source_data     (normalizer_source[n]),
        .center          (pid_input_center[(n+2)*32 +: 32]),
        .scale           (pid_input_scale[(n+2)*32 +: 32]),

        .normalized_data (normalizer_output[n]),
        .out_valid       (normalizer_valid[n])
      );

    end

  endgenerate


  // =========================================================================
  // 4 x PID
  //
  // PID0 / PID1 = wrapped phase error
  // PID2 / PID3 = normal arithmetic error
  // =========================================================================

  genvar p;

  generate

    for (p = 0; p < 4; p = p + 1) begin : GEN_PID

      if (p < 2) begin : PHASE_PID

        pid_core #(
          .PHASE_MODE(1)
        ) i_pid (

          .clk           (adc_test_clk),
          .rst           (1'b0),

          .update        (pid_update[p]),
          .enable        (pid_enable[p]),
          .reset_pid     (pid_reset_pulse_adc[p]),

          .input_data    (pid_input[p]),
          .setpoint      (pid_setpoint[p*32 +: 32]),

          .kp            (pid_kp[p*32 +: 32]),
          .ki            (pid_ki[p*32 +: 32]),
          .kd            (pid_kd[p*32 +: 32]),

          .out_min       (pid_out_min[p*32 +: 32]),
          .out_max       (pid_out_max[p*32 +: 32]),

          .output_data   (pid_output[p*32 +: 32]),
          .error_out     (pid_error[p*32 +: 32]),
          .integrator_out(pid_integrator[p*32 +: 32]),

          .status        (pid_status[p*32 +: 32])
        );

      end else begin : GENERAL_PID

        pid_core #(
          .PHASE_MODE(0)
        ) i_pid (

          .clk           (adc_test_clk),
          .rst           (1'b0),

          .update        (pid_update[p]),
          .enable        (pid_enable[p]),
          .reset_pid     (pid_reset_pulse_adc[p]),

          .input_data    (pid_input[p]),
          .setpoint      (pid_setpoint[p*32 +: 32]),

          .kp            (pid_kp[p*32 +: 32]),
          .ki            (pid_ki[p*32 +: 32]),
          .kd            (pid_kd[p*32 +: 32]),

          .out_min       (pid_out_min[p*32 +: 32]),
          .out_max       (pid_out_max[p*32 +: 32]),

          .output_data   (pid_output[p*32 +: 32]),
          .error_out     (pid_error[p*32 +: 32]),
          .integrator_out(pid_integrator[p*32 +: 32]),

          .status        (pid_status[p*32 +: 32])
        );

      end

    end

  endgenerate


  // =========================================================================
  // AO routing + scaling
  //
  // source_sel:
  //
  // 0 = manual
  // 1 = PID0
  // 2 = PID1
  // 3 = PID2
  // 4 = PID3
  // =========================================================================

  genvar a;

  generate

    for (a = 0; a < 4; a = a + 1) begin : GEN_AO

      wire [2:0] source_sel;

      assign source_sel =
        ao_source_sel[a*3 +: 3];


      assign ao_source[a] =

        (source_sel == 3'd0) ?
          {16'd0, ao_manual_code[a*16 +: 16]} :

        (source_sel == 3'd1) ?
          pid_output[31:0] :

        (source_sel == 3'd2) ?
          pid_output[63:32] :

        (source_sel == 3'd3) ?
          pid_output[95:64] :

        (source_sel == 3'd4) ?
          pid_output[127:96] :

          32'sd0;


      ao_scaler i_ao_scaler (
        .clk         (adc_test_clk),

        .source_data (ao_source[a]),
        .gain        (ao_gain[a*32 +: 32]),
        .offset      (ao_offset[a*32 +: 32]),

        .out_min     (ao_out_min[a*32 +: 32]),
        .out_max     (ao_out_max[a*32 +: 32]),

        .output_code (ao_output[a*16 +: 16]),
        .status      (ao_status[a*32 +: 32])
      );
    end

  endgenerate


  // =========================================================================
  // Physical Pmod DA3 outputs
  //
  // AO0 -> JA upper row (JA1..JA4)
  // AO1 -> JA lower row (JA7..JA10)
  // AO2 -> JB upper row (JB1..JB4)
  // AO3 -> JB lower row (JB7..JB10)
  // =========================================================================

  da3_driver i_da3_driver_0 (
    .clk      (da3_clk),
    .rst      (da3_rst),
    .dac_code (ao_output[15:0]),
    .sclk     (da3_sclk),
    .sdin     (da3_sdin),
    .sync     (da3_sync),
    .ldac     (da3_ldac)
  );

  da3_driver i_da3_driver_1 (
    .clk      (da3_clk),
    .rst      (da3_rst),
    .dac_code (ao_output[31:16]),
    .sclk     (da3_1_sclk),
    .sdin     (da3_1_sdin),
    .sync     (da3_1_sync),
    .ldac     (da3_1_ldac)
  );

  da3_driver i_da3_driver_2 (
    .clk      (da3_clk),
    .rst      (da3_rst),
    .dac_code (ao_output[47:32]),
    .sclk     (da3_2_sclk),
    .sdin     (da3_2_sdin),
    .sync     (da3_2_sync),
    .ldac     (da3_2_ldac)
  );

  da3_driver i_da3_driver_3 (
    .clk      (da3_clk),
    .rst      (da3_rst),
    .dac_code (ao_output[63:48]),
    .sclk     (da3_3_sclk),
    .sdin     (da3_3_sdin),
    .sync     (da3_3_sync),
    .ldac     (da3_3_ldac)
  );


  // =========================================================================
  // AO4/AO5: 20-bit scaling and native AD5791 SPI on ADC clock (50 MHz).
  // No 50 -> 100 MHz multi-bit CDC: scaler and SPI share adc_test_clk.
  // Keep existing AO0..AO3 / DA3 modules unmodified.
  // =========================================================================

  genvar a20;
  generate
    for (a20 = 0; a20 < 2; a20 = a20 + 1) begin : GEN_AO20
      wire [2:0] source_sel20;
      assign source_sel20 = ao20_source_sel[a20*3 +: 3];

      assign ao20_source[a20] =
        (source_sel20 == 3'd0) ? {12'd0, ao20_manual_code[a20*20 +: 20]} :
        (source_sel20 == 3'd1) ? $signed(pid_output[31:0]) :
        (source_sel20 == 3'd2) ? $signed(pid_output[63:32]) :
        (source_sel20 == 3'd3) ? $signed(pid_output[95:64]) :
        (source_sel20 == 3'd4) ? $signed(pid_output[127:96]) :
        32'sd0;

      ao_scaler_20bit i_ao_scaler_20bit (
        .clk         (adc_test_clk),
        .source_data (ao20_source[a20]),
        .gain        (ao20_gain[a20*32 +: 32]),
        .offset      (ao20_offset[a20*32 +: 32]),
        .out_min     (ao20_out_min[a20*32 +: 32]),
        .out_max     (ao20_out_max[a20*32 +: 32]),
        .output_code (ao20_output[a20*20 +: 20]),
        .status      (ao20_status[a20*32 +: 32])
      );
    end
  endgenerate

  // At 50 MHz: SPI_HALF_CYCLES=5 -> 5 MHz SCLK, conservative timing.
  // STARTUP_CYCLES=500000 -> 10 ms (matches driver's 100 MHz default time).
  // RESET_WAIT_CYCLES=8 -> 160 ns. CS/LDAC low = 100 ns each.
  // All six digital control pins are exported; no assumed board strapping.
  ad5791_driver #(
    .SPI_HALF_CYCLES(5),
    .STARTUP_CYCLES(500000),
    .RESET_WAIT_CYCLES(8),
    .CS_HIGH_CYCLES(5),
    .LDAC_LOW_CYCLES(5)
  ) i_ad5791_jc (
    .clk      (adc_test_clk),
    .rst      (1'b0),
    .dac_code (ao20_output[19:0]),
    .sclk     (cn0531_jc_sclk),
    .sdin     (cn0531_jc_sdin),
    .sync_n   (cn0531_jc_sync_n),
    .ldac_n   (cn0531_jc_ldac_n),
    .reset_n  (cn0531_jc_reset_n),
    .clr_n    (cn0531_jc_clr_n),
    .ready    (),
    .busy     ()
  );

  ad5791_driver #(
    .SPI_HALF_CYCLES(5),
    .STARTUP_CYCLES(500000),
    .RESET_WAIT_CYCLES(8),
    .CS_HIGH_CYCLES(5),
    .LDAC_LOW_CYCLES(5)
  ) i_ad5791_jd (
    .clk      (adc_test_clk),
    .rst      (1'b0),
    .dac_code (ao20_output[39:20]),
    .sclk     (cn0531_jd_sclk),
    .sdin     (cn0531_jd_sdin),
    .sync_n   (cn0531_jd_sync_n),
    .ldac_n   (cn0531_jd_ldac_n),
    .reset_n  (cn0531_jd_reset_n),
    .clr_n    (cn0531_jd_clr_n),
    .ready    (),
    .busy     ()
  );

  // =========================================================================
  // System block design wrapper
  // =========================================================================

  system_wrapper i_system_wrapper (

    .clk_in   (clk_in),
    .ready_in (ready_in),
    .data_in  (data_in),

    .ddr_addr    (ddr_addr),
    .ddr_ba      (ddr_ba),
    .ddr_cas_n   (ddr_cas_n),
    .ddr_ck_n    (ddr_ck_n),
    .ddr_ck_p    (ddr_ck_p),
    .ddr_cke     (ddr_cke),
    .ddr_cs_n    (ddr_cs_n),
    .ddr_dm      (ddr_dm),
    .ddr_dq      (ddr_dq),
    .ddr_dqs_n   (ddr_dqs_n),
    .ddr_dqs_p   (ddr_dqs_p),
    .ddr_odt     (ddr_odt),
    .ddr_ras_n   (ddr_ras_n),
    .ddr_reset_n (ddr_reset_n),
    .ddr_we_n    (ddr_we_n),

    .fixed_io_ddr_vrn  (fixed_io_ddr_vrn),
    .fixed_io_ddr_vrp  (fixed_io_ddr_vrp),
    .fixed_io_mio      (fixed_io_mio),
    .fixed_io_ps_clk   (fixed_io_ps_clk),
    .fixed_io_ps_porb  (fixed_io_ps_porb),
    .fixed_io_ps_srstb (fixed_io_ps_srstb),

    .gpio_i (gpio_i),
    .gpio_o (gpio_o),
    .gpio_t (gpio_t),

    .hdmi_data    (hdmi_data),
    .hdmi_data_e  (hdmi_data_e),
    .hdmi_hsync   (hdmi_hsync),
    .hdmi_out_clk (hdmi_out_clk),
    .hdmi_vsync   (hdmi_vsync),

    .i2s_bclk      (i2s_bclk),
    .i2s_lrclk     (i2s_lrclk),
    .i2s_mclk      (i2s_mclk),
    .i2s_sdata_in  (i2s_sdata_in),
    .i2s_sdata_out (i2s_sdata_out),

    .iic_fmc_scl_io (iic_scl),
    .iic_fmc_sda_io (iic_sda),

    .iic_mux_scl_i (iic_mux_scl_i_s),
    .iic_mux_scl_o (iic_mux_scl_o_s),
    .iic_mux_scl_t (iic_mux_scl_t_s),

    .iic_mux_sda_i (iic_mux_sda_i_s),
    .iic_mux_sda_o (iic_mux_sda_o_s),
    .iic_mux_sda_t (iic_mux_sda_t_s),

    .otg_vbusoc (otg_vbusoc),

    .spdif (spdif),

    .spi0_clk_i   (1'b0),
    .spi0_clk_o   (spi_clk),
    .spi0_csn_0_o (spi_csn),
    .spi0_csn_1_o (),
    .spi0_csn_2_o (),
    .spi0_csn_i   (1'b1),
    .spi0_sdi_i   (spi_miso),
    .spi0_sdo_i   (1'b0),
    .spi0_sdo_o   (spi_mosi),

    .spi1_clk_i   (1'b0),
    .spi1_clk_o   (),
    .spi1_csn_0_o (),
    .spi1_csn_1_o (),
    .spi1_csn_2_o (),
    .spi1_csn_i   (1'b1),
    .spi1_sdi_i   (1'b0),
    .spi1_sdo_i   (1'b0),
    .spi1_sdo_o   (),

    // -----------------------------------------------------------------------
    // ADC / clocks
    // -----------------------------------------------------------------------

    .da3_clk      (da3_clk),
    .adc_test_clk (adc_test_clk),

    .adc_valid  (adc_valid),

    .adc_data_0 (adc_data_0),
    .adc_data_1 (adc_data_1),
    .adc_data_2 (adc_data_2),
    .adc_data_3 (adc_data_3),

    // -----------------------------------------------------------------------
    // Average
    // -----------------------------------------------------------------------
    .phase_valid (cordic_out_valid[0]),
    
    .avg0      (avg0),
    .avg1      (avg1),
    .avg2      (avg2),
    .avg3      (avg3),

    // Wrapped CORDIC0/1 phase stream, signed32 BAM
    .cordic_phase (cordic_phase[63:0]),

    .avg_shift (avg_shift_shadow),

    // -----------------------------------------------------------------------
    // Legacy DAC register
    // -----------------------------------------------------------------------

    .dac_code (dac_code),

    // -----------------------------------------------------------------------
    // CORDIC packed
    // -----------------------------------------------------------------------

    .cordic_sel_x  (cordic_sel_x_shadow),
    .cordic_sel_y  (cordic_sel_y_shadow),

    // -----------------------------------------------------------------------
    // PID packed
    // -----------------------------------------------------------------------

    .pid_enable       (pid_enable_shadow),
    .pid_reset_toggle (pid_reset_toggle),

    .pid_input_sel    (pid_input_sel_shadow),

    .pid_input_center (pid_input_center_shadow),
    .pid_input_scale   (pid_input_scale_shadow),
    .pid_setpoint     (pid_setpoint_shadow),

    .pid_kp           (pid_kp_shadow),
    .pid_ki           (pid_ki_shadow),
    .pid_kd           (pid_kd_shadow),

    .pid_out_min      (pid_out_min_shadow),
    .pid_out_max      (pid_out_max_shadow),

    // -----------------------------------------------------------------------
    // AO packed
    // -----------------------------------------------------------------------

    .ao_source_sel  (ao_source_sel_shadow),
    .ao_manual_code (ao_manual_code_shadow),

    .ao_gain        (ao_gain_shadow),
    .ao_offset      (ao_offset_shadow),

    .ao_out_min     (ao_out_min_shadow),
    .ao_out_max     (ao_out_max_shadow),

    // These six wrapper ports require matching exports in system_bd.tcl
    // (the next file to edit; intentionally not changed in this step).
    .ao20_source_sel  (ao20_source_sel_shadow),
    .ao20_manual_code (ao20_manual_code_shadow),
    .ao20_gain        (ao20_gain_shadow),
    .ao20_offset      (ao20_offset_shadow),
    .ao20_out_min     (ao20_out_min_shadow),
    .ao20_out_max     (ao20_out_max_shadow),

    .ao_output      (ao_output),

    // One-way APPLY command
    .apply_toggle (apply_toggle)

  );

endmodule