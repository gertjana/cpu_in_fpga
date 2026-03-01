// =============================================================================
// i2c_master.v — streaming I2C master for SSD1306
//
// Sends one I2C transaction with variable-length payload:
//   START → addr+W → control_byte → data[0] → data[1] → ... → STOP
//
// Streaming interface:
//   1. Caller asserts start=1 for one cycle, presenting the first byte on
//      data[] and asserting last=1 if it is the only byte.
//      busy goes high on the next clock.
//   2. After the control byte ACK, the master begins sending data bytes.
//      Before each subsequent byte (after data[0]) it asserts req=1 for one
//      cycle. The caller must present the next byte on data[] in the cycle
//      AFTER req, and assert last=1 if that byte is the final one.
//   3. After the final byte's ACK, STOP is issued and busy falls.
//
// SCL period = 4 × T_WAIT clk cycles.
//   T_WAIT=15 → 200 kHz at 12 MHz.
//
// Push-pull drive — no open-drain needed for short PMOD traces at 3.3 V.
//
// Verilog-2005.
// =============================================================================

module i2c_master #(
    parameter T_WAIT = 15
) (
    input            clk,
    input            rst,
    input            start,     // 1-cycle pulse: launch transaction
    input            dcn,       // 0=command stream, 1=data stream
    input      [7:0] data,      // byte to send (valid when start=1 or req=1)
    input            last,      // 1 = this is the last byte
    output reg       busy,
    output reg       req,       // 1-cycle pulse: need next byte; caller presents it next cycle
    output reg       scl,
    output reg       sda
);

// ---------------------------------------------------------------------------
localparam [6:0] SSD1306_ADDR = 7'h3C;
localparam [7:0] CTRL_CMD     = 8'h00;
localparam [7:0] CTRL_DATA    = 8'h40;

localparam S_IDLE      = 4'd0;
localparam S_START     = 4'd1;
localparam S_ADDR      = 4'd2;
localparam S_ADDR_ACK  = 4'd3;
localparam S_CTRL      = 4'd4;
localparam S_CTRL_ACK  = 4'd5;
localparam S_DATA      = 4'd6;
localparam S_DATA_ACK  = 4'd7;
localparam S_DATA_LOAD = 4'd8;  // one-cycle pause to load next byte from caller
localparam S_STOP      = 4'd9;

reg [3:0] state;

// ---------------------------------------------------------------------------
// Quarter-period timer — counts while busy, resets on timer_done
// ---------------------------------------------------------------------------
reg [7:0] wait_ctr;
wire timer_done = (wait_ctr == T_WAIT - 1);

always @(posedge clk) begin
    if (rst || timer_done)
        wait_ctr <= 8'd0;
    else if (busy)
        wait_ctr <= wait_ctr + 1'b1;
end

// ---------------------------------------------------------------------------
reg [2:0] bit_ctr;
reg [1:0] phase;
reg [7:0] shift_r;   // current byte being shifted out
reg [7:0] data0_r;   // saved copy of the first data byte
reg [7:0] ctrl_r;    // control byte (00 or 40)
reg       last_r;    // last flag for current byte

// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        state   <= S_IDLE;
        busy    <= 1'b0;
        req     <= 1'b0;
        scl     <= 1'b1;
        sda     <= 1'b1;
        bit_ctr <= 3'd0;
        phase   <= 2'd0;
        last_r  <= 1'b0;
    end else begin
        req <= 1'b0; // default

        case (state)

            // -----------------------------------------------------------------
            S_IDLE: begin
                scl <= 1'b1;
                sda <= 1'b1;
                if (start) begin
                    ctrl_r  <= dcn ? CTRL_DATA : CTRL_CMD;
                    data0_r <= data;   // save first byte; shift_r used for addr/ctrl
                    last_r  <= last;
                    busy    <= 1'b1;
                    phase   <= 2'd0;
                    state   <= S_START;
                end
            end

            // -----------------------------------------------------------------
            // START condition
            // -----------------------------------------------------------------
            S_START: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin sda <= 1'b0; phase <= 2'd1; end          // SDA falls
                        2'd1: begin                                            // SCL falls
                            scl     <= 1'b0;
                            shift_r <= {SSD1306_ADDR, 1'b0};  // addr+W
                            bit_ctr <= 3'd7;
                            phase   <= 2'd0;
                            state   <= S_ADDR;
                        end
                        default: ;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // Byte transmit (ADDR / CTRL / DATA)
            // phase 0: drive SDA from MSB
            // phase 1: SCL high
            // phase 2: hold
            // phase 3: SCL low; last bit → ACK state
            // -----------------------------------------------------------------
            S_ADDR, S_CTRL, S_DATA: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin sda <= shift_r[7]; phase <= 2'd1; end
                        2'd1: begin scl <= 1'b1;        phase <= 2'd2; end
                        2'd2: begin                      phase <= 2'd3; end
                        2'd3: begin
                            scl   <= 1'b0;
                            phase <= 2'd0;
                            if (bit_ctr == 3'd0) begin
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
            // ACK pulse (ignore value — push-pull can't read ACK anyway)
            // phase 0: SCL high
            // phase 1: hold
            // phase 2: SCL low → advance
            // -----------------------------------------------------------------
            S_ADDR_ACK, S_CTRL_ACK, S_DATA_ACK: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin scl <= 1'b1; phase <= 2'd1; end
                        2'd1: begin               phase <= 2'd2; end
                        2'd2: begin
                            scl   <= 1'b0;
                            phase <= 2'd0;
                            case (state)
                                S_ADDR_ACK: begin
                                    shift_r <= ctrl_r;
                                    bit_ctr <= 3'd7;
                                    state   <= S_CTRL;
                                end
                                S_CTRL_ACK: begin
                                    // First data byte was saved in data0_r
                                    shift_r <= data0_r;
                                    bit_ctr <= 3'd7;
                                    state   <= S_DATA;
                                end
                                S_DATA_ACK: begin
                                    if (last_r) begin
                                        state <= S_STOP;
                                    end else begin
                                        // Request next byte from caller
                                        req   <= 1'b1;
                                        state <= S_DATA_LOAD;
                                    end
                                end
                                default: ;
                            endcase
                        end
                        default: ;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // S_DATA_LOAD: caller is presenting next byte on data[]/last this cycle
            // (req was asserted last cycle, caller responds this cycle)
            // -----------------------------------------------------------------
            S_DATA_LOAD: begin
                // Wait one timer tick so the caller's registered output settles
                if (timer_done) begin
                    shift_r <= data;
                    last_r  <= last;
                    bit_ctr <= 3'd7;
                    state   <= S_DATA;
                end
            end

            // -----------------------------------------------------------------
            // STOP: SDA rises while SCL high
            // phase 0: ensure SDA low, raise SCL
            // phase 1: raise SDA → STOP condition
            // phase 2: done
            // -----------------------------------------------------------------
            S_STOP: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin sda <= 1'b0; scl <= 1'b1; phase <= 2'd1; end
                        2'd1: begin sda <= 1'b1;               phase <= 2'd2; end
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
