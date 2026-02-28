// =============================================================================
// i2c_master.v — minimal I2C master for SSD1306 (one transaction at a time)
//
// Sends exactly one I2C transaction per invocation:
//   START  →  addr byte (0x78 = 0x3C<<1 | 0=write)
//          →  control byte (0x00 = command stream, 0x40 = data stream)
//          →  data byte
//          →  STOP
//
// Handshake:
//   Caller asserts start=1 for one clk cycle.
//   busy goes high immediately and stays high until STOP is complete.
//   Caller must not assert start again while busy=1.
//
// Clock division:
//   SCL period = 4 * T_WAIT clk cycles.
//   Default T_WAIT=15 → SCL period = 60 cycles @ 12 MHz = ~200 kHz.
//   (SSD1306 supports up to 400 kHz; 200 kHz is conservative and safe.)
//
// Push-pull drive (not open-drain) — fine for short traces at 3.3 V.
//
// Verilog-2005.
// =============================================================================

module i2c_master #(
    parameter T_WAIT = 15           // quarter-period in clk cycles
) (
    input            clk,
    input            rst,
    input            start,         // 1-cycle pulse: begin transaction
    input            dcn,           // 0 = command byte, 1 = data byte
    input      [7:0] data,          // byte to send after control byte
    output reg       busy,
    output reg       scl,
    output reg       sda
);

// ---------------------------------------------------------------------------
// SSD1306 I2C address and control bytes
// ---------------------------------------------------------------------------
localparam [6:0] SSD1306_ADDR = 7'h3C;
localparam [7:0] CTRL_CMD     = 8'h00;  // Co=0 D/C#=0 → command stream
localparam [7:0] CTRL_DATA    = 8'h40;  // Co=0 D/C#=1 → data stream

// ---------------------------------------------------------------------------
// State encoding
// ---------------------------------------------------------------------------
localparam S_IDLE      = 4'd0;
localparam S_START     = 4'd1;  // pull SDA low while SCL high
localparam S_ADDR      = 4'd2;  // send 7-bit addr + W bit (8 bits)
localparam S_ADDR_ACK  = 4'd3;  // release SDA, clock ACK bit
localparam S_CTRL      = 4'd4;  // send control byte
localparam S_CTRL_ACK  = 4'd5;  // ACK for control byte
localparam S_DATA      = 4'd6;  // send data byte
localparam S_DATA_ACK  = 4'd7;  // ACK for data byte
localparam S_STOP      = 4'd8;  // pull SDA high while SCL high

reg [3:0] state;

// ---------------------------------------------------------------------------
// Quarter-period timer
// T_WAIT fits in 8 bits for any reasonable clock frequency.
// ---------------------------------------------------------------------------
reg [7:0] wait_ctr;
wire timer_done = (wait_ctr == T_WAIT - 1);

always @(posedge clk) begin
    if (rst || timer_done)
        wait_ctr <= 0;
    else if (busy)
        wait_ctr <= wait_ctr + 1'b1;
end

// ---------------------------------------------------------------------------
// Bit counter (counts 0..7 for each byte)
// ---------------------------------------------------------------------------
reg [2:0] bit_ctr;

// ---------------------------------------------------------------------------
// Latched copies of dcn/data (captured on start)
// ---------------------------------------------------------------------------
reg       dcn_r;
reg [7:0] data_r;
reg [7:0] ctrl_r;       // computed control byte
reg [7:0] shift_r;      // shift register for current byte being sent

// SCL phase sub-counter: we split each bit into 4 T_WAIT phases:
//   0: SCL low,  SDA set
//   1: SCL rises
//   2: SCL high  (sample point for ACK)
//   3: SCL falls
reg [1:0] phase;

// ---------------------------------------------------------------------------
// Main FSM
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        state   <= S_IDLE;
        busy    <= 1'b0;
        scl     <= 1'b1;
        sda     <= 1'b1;
        bit_ctr <= 3'd0;
        phase   <= 2'd0;
    end else begin
        case (state)

            // -----------------------------------------------------------------
            S_IDLE: begin
                scl <= 1'b1;
                sda <= 1'b1;
                if (start) begin
                    dcn_r  <= dcn;
                    data_r <= data;
                    ctrl_r <= dcn ? CTRL_DATA : CTRL_CMD;
                    busy   <= 1'b1;
                    state  <= S_START;
                    phase  <= 2'd0;
                end
            end

            // -----------------------------------------------------------------
            // START condition: SDA falls while SCL is high.
            // We use two T_WAIT phases:
            //   phase 0: SCL=1 SDA=1 (already there from IDLE)
            //   phase 1: SCL=1 SDA=0  → START
            // Then fall into first byte with SCL low.
            // -----------------------------------------------------------------
            S_START: begin
                if (timer_done) begin
                    phase <= phase + 1'b1;
                    case (phase)
                        2'd0: begin scl <= 1'b1; sda <= 1'b0; end  // SDA falls
                        2'd1: begin scl <= 1'b0; sda <= 1'b0;      // SCL falls → addr
                               shift_r <= {SSD1306_ADDR, 1'b0};    // addr + write
                               bit_ctr <= 3'd7;
                               phase   <= 2'd0;
                               state   <= S_ADDR;
                              end
                        default: ;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // Send byte states: ADDR / CTRL / DATA
            // 4 phases per bit: set SDA | SCL high | hold | SCL low
            // -----------------------------------------------------------------
            S_ADDR, S_CTRL, S_DATA: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin
                            sda   <= shift_r[7];
                            phase <= 2'd1;
                        end
                        2'd1: begin
                            scl   <= 1'b1;
                            phase <= 2'd2;
                        end
                        2'd2: begin
                            phase <= 2'd3;
                        end
                        2'd3: begin
                            scl   <= 1'b0;
                            phase <= 2'd0;
                            if (bit_ctr == 3'd0) begin
                                // Byte done — move to ACK
                                sda <= 1'b1;  // release SDA for ACK
                                case (state)
                                    S_ADDR: state <= S_ADDR_ACK;
                                    S_CTRL: state <= S_CTRL_ACK;
                                    S_DATA: state <= S_DATA_ACK;
                                    default: ;
                                endcase
                            end else begin
                                shift_r <= {shift_r[6:0], 1'b0};
                                bit_ctr <= bit_ctr - 1'b1;
                            end
                        end
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // ACK phase: SCL pulse while SDA released (slave drives 0).
            // We do not verify ACK — just clock it and move on.
            // -----------------------------------------------------------------
            S_ADDR_ACK, S_CTRL_ACK, S_DATA_ACK: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin scl <= 1'b1; phase <= 2'd1; end
                        2'd1: begin phase <= 2'd2; end
                        2'd2: begin scl <= 1'b0; phase <= 2'd0;
                               case (state)
                                   S_ADDR_ACK: begin
                                       shift_r <= ctrl_r;
                                       bit_ctr <= 3'd7;
                                       state   <= S_CTRL;
                                   end
                                   S_CTRL_ACK: begin
                                       shift_r <= data_r;
                                       bit_ctr <= 3'd7;
                                       state   <= S_DATA;
                                   end
                                   S_DATA_ACK: begin
                                       state <= S_STOP;
                                   end
                                   default: ;
                               endcase
                              end
                        default: ;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // STOP condition: SDA rises while SCL is high.
            // phase 0: SCL=0  SDA=0
            // phase 1: SCL=1  SDA=0
            // phase 2: SCL=1  SDA=1  → STOP
            // -----------------------------------------------------------------
            S_STOP: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin sda <= 1'b0; scl <= 1'b1; phase <= 2'd1; end
                        2'd1: begin sda <= 1'b1; phase <= 2'd2; end
                        2'd2: begin busy <= 1'b0; state <= S_IDLE; phase <= 2'd0; end
                        default: ;
                    endcase
                end
            end

            default: state <= S_IDLE;

        endcase
    end
end

endmodule
