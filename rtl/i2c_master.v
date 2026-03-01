// =============================================================================
// i2c_master.v — streaming I2C master for SSD1306
//
// Sends one I2C transaction with a variable-length payload:
//   START → addr+W → control_byte → data[0] → data[1] → ... → STOP
//
// Streaming interface:
//   1. Assert start=1 with dcn and first data byte on data[].
//      busy goes high on the next clock.
//   2. After addr+W ACK and control byte ACK, the master begins clocking
//      data bytes. It asserts req=1 one cycle before it needs the next byte.
//   3. Caller presents the next byte on data[] and asserts last=1 if it is
//      the final byte.
//   4. After the final byte's ACK, STOP is issued and busy falls.
//
// If only one byte is needed (last=1 when start fires), the transaction is:
//   START → addr+W → ctrl → data[0] → STOP
//
// Clock: SCL period = 4 × T_WAIT clk cycles.
//   T_WAIT=15 → 200 kHz at 12 MHz (SSD1306 max 400 kHz).
//
// Push-pull drive — no open-drain needed for short traces at 3.3 V.
//
// Verilog-2005.
// =============================================================================

module i2c_master #(
    parameter T_WAIT = 15
) (
    input            clk,
    input            rst,
    // Transaction start
    input            start,     // 1-cycle pulse: launch transaction
    input            dcn,       // 0=command stream, 1=data stream (control byte)
    input      [7:0] data,      // current byte (valid when start=1 or req=1)
    input            last,      // 1 = this is the last byte of the transaction
    // Flow control
    output reg       busy,      // high for entire transaction
    output reg       req,       // 1 = need next byte on data[] next cycle
    // I2C bus
    output reg       scl,
    output reg       sda
);

// ---------------------------------------------------------------------------
localparam [6:0] SSD1306_ADDR = 7'h3C;
localparam [7:0] CTRL_CMD     = 8'h00;
localparam [7:0] CTRL_DATA    = 8'h40;

// ---------------------------------------------------------------------------
localparam S_IDLE      = 4'd0;
localparam S_START     = 4'd1;
localparam S_ADDR      = 4'd2;
localparam S_ADDR_ACK  = 4'd3;
localparam S_CTRL      = 4'd4;
localparam S_CTRL_ACK  = 4'd5;
localparam S_DATA      = 4'd6;
localparam S_DATA_ACK  = 4'd7;
localparam S_STOP      = 4'd8;

reg [3:0] state;

// ---------------------------------------------------------------------------
// Quarter-period timer
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
reg [7:0] shift_r;
reg [7:0] ctrl_r;
reg       last_r;   // latched last flag for current data byte

// ---------------------------------------------------------------------------
// Main FSM
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
        req <= 1'b0; // default deassert

        case (state)

            // -----------------------------------------------------------------
            S_IDLE: begin
                scl <= 1'b1;
                sda <= 1'b1;
                if (start) begin
                    ctrl_r  <= dcn ? CTRL_DATA : CTRL_CMD;
                    shift_r <= data;   // first data byte, held for later
                    last_r  <= last;
                    busy    <= 1'b1;
                    phase   <= 2'd0;
                    state   <= S_START;
                end
            end

            // -----------------------------------------------------------------
            // START: SDA falls while SCL high, then SCL falls
            // phase 0 → SDA low (START condition)
            // phase 1 → SCL low, load addr byte, go to S_ADDR
            // -----------------------------------------------------------------
            S_START: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin
                            sda   <= 1'b0;
                            phase <= 2'd1;
                        end
                        2'd1: begin
                            scl     <= 1'b0;
                            shift_r <= {SSD1306_ADDR, 1'b0};
                            bit_ctr <= 3'd7;
                            phase   <= 2'd0;
                            state   <= S_ADDR;
                        end
                        default: ;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // Byte transmit: ADDR / CTRL / DATA
            // phase 0: set SDA from MSB
            // phase 1: SCL high
            // phase 2: hold (sample point)
            // phase 3: SCL low; if last bit → ACK state
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
                                sda <= 1'b1; // release for ACK
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
            // ACK: one SCL pulse (we ignore the ACK value)
            // phase 0: SCL high
            // phase 1: hold
            // phase 2: SCL low → load next state
            // -----------------------------------------------------------------
            S_ADDR_ACK, S_CTRL_ACK, S_DATA_ACK: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin scl <= 1'b1; phase <= 2'd1; end
                        2'd1: begin phase <= 2'd2; end
                        2'd2: begin
                            scl   <= 1'b0;
                            phase <= 2'd0;
                            case (state)
                                S_ADDR_ACK: begin
                                    // Send control byte
                                    shift_r <= ctrl_r;
                                    bit_ctr <= 3'd7;
                                    state   <= S_CTRL;
                                end
                                S_CTRL_ACK: begin
                                    // Send first data byte (already in shift_r from start)
                                    // shift_r was loaded with data at start; reload it.
                                    bit_ctr <= 3'd7;
                                    state   <= S_DATA;
                                    // shift_r still holds the first data byte from S_IDLE
                                end
                                S_DATA_ACK: begin
                                    if (last_r) begin
                                        // No more bytes — issue STOP
                                        state <= S_STOP;
                                    end else begin
                                        // Request next byte; caller must present it next cycle.
                                        req    <= 1'b1;
                                        state  <= S_DATA_ACK; // hold one extra cycle for data
                                        phase  <= 2'd3;       // sentinel: wait for data
                                    end
                                end
                                default: ;
                            endcase
                        end
                        // Sentinel phase 3: data is now valid on data[]/last
                        2'd3: begin
                            shift_r <= data;
                            last_r  <= last;
                            bit_ctr <= 3'd7;
                            phase   <= 2'd0;
                            state   <= S_DATA;
                        end
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // STOP: SDA rises while SCL high
            // phase 0: SDA low, SCL high
            // phase 1: SDA high → STOP condition
            // phase 2: done
            // -----------------------------------------------------------------
            S_STOP: begin
                if (timer_done) begin
                    case (phase)
                        2'd0: begin sda <= 1'b0; scl <= 1'b1; phase <= 2'd1; end
                        2'd1: begin sda <= 1'b1; phase <= 2'd2; end
                        2'd2: begin
                            busy  <= 1'b0;
                            state <= S_IDLE;
                            phase <= 2'd0;
                        end
                        default: ;
                    endcase
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
