// =============================================================================
// cpu.v — Top-level 8-bit CPU
//
// Architecture: Harvard, single-issue, two-cycle fetch+execute pipeline.
//
// Pipeline timing:
//   Cycle N  : PC presented to ROM as fetch address
//   Cycle N+1: ROM output valid → decoder → datapath executes combinationally
//              → register / memory / stack / PC updated on rising edge of N+1
//
// Instruction formats, ISA and control signals are defined in decoder.v.
//
// Ports:
//   clk      — clock (rising edge)
//   rst      — synchronous reset
//   halt_out — asserted from the HALT cycle and held permanently
//   dbg_pc   — current program counter value (for LED / debug)
//   dbg_flag_z/c/n/v — current flag register values (for LED / debug)
// =============================================================================

module cpu #(
    parameter ROM_INIT = "program.hex"
) (
    input  wire       clk,
    input  wire       rst,
    output wire       halt_out,
    // PRNG advance: tie high to run the LFSR at full board clock rate
    // (driven from top.v with the board clock, not the slow CPU clock)
    input  wire       prng_advance,
    // Debug / LED outputs (combinational taps of internal state)
    output wire [7:0] dbg_pc,
    output wire       dbg_flag_z,
    output wire       dbg_flag_c,
    output wire       dbg_flag_n,
    output wire       dbg_flag_v,
    output wire [7:0] dbg_r7,
    output wire [7:0] dbg_stack_top,   // current top-of-stack value (combinational peek)
    output wire       dbg_stack_empty  // stack is empty
);

// ---------------------------------------------------------------------------
// Internal wires — decoder outputs
// ---------------------------------------------------------------------------
wire [2:0]  dec_rd_addr;
wire [2:0]  dec_ra_addr;
wire [2:0]  dec_rb_addr;
wire        dec_reg_we;
wire [2:0]  dec_alu_op;
wire        dec_alu_src_b;
wire [7:0]  dec_imm;
wire [2:0]  dec_wb_sel;
wire        dec_mem_re;
wire        dec_mem_we;
wire        dec_pc_load;
wire [7:0]  dec_pc_target;
wire        dec_stack_push;
wire        dec_stack_pop;
wire        dec_flags_we;
wire        dec_halt;

// ---------------------------------------------------------------------------
// Instruction register (ROM output) with branch-delay-slot flush and
// halt sticky latch.
//
// flush_r: inserted NOP cycle after every taken branch (ROM latency compensation)
// halted:  sticky flag — once HALT executes, all subsequent ROM outputs are
//          replaced with NOP and pc.halt is held permanently.
// ---------------------------------------------------------------------------
wire [15:0] rom_out;    // raw ROM output
reg         flush_r;   // 1 = suppress next instruction (replace with NOP)
reg         halted;    // 1 = CPU has executed HALT and is permanently frozen
wire [15:0] instr;     // instruction presented to decoder

assign instr = (flush_r || halted) ? 16'hE000 : rom_out;

// flush_r is set the cycle a branch/jump is taken; cleared next cycle
// halted is set the cycle dec_halt is seen; never cleared (only rst)
always @(posedge clk) begin
    if (rst) begin
        flush_r <= 1'b0;
        halted  <= 1'b0;
    end else begin
        flush_r <= dec_pc_load & ~dec_halt;   // no flush needed after HALT
        if (dec_halt)
            halted <= 1'b1;
    end
end

// ---------------------------------------------------------------------------
// PC wires
// ---------------------------------------------------------------------------
wire [7:0] pc_out;
wire [7:0] pc_next;
wire [7:0] pc_in;

// ---------------------------------------------------------------------------
// Register file wires
// ---------------------------------------------------------------------------
wire [7:0] ra_data;
wire [7:0] rb_data;
wire [7:0] wb_data;

// ---------------------------------------------------------------------------
// ALU wires
// ---------------------------------------------------------------------------
wire [7:0] alu_b;
wire [7:0] alu_result;
wire       alu_z, alu_c, alu_n, alu_v;

// ---------------------------------------------------------------------------
// Flag register
// ---------------------------------------------------------------------------
reg flag_z, flag_c, flag_n, flag_v;

// ---------------------------------------------------------------------------
// RAM wires
// ---------------------------------------------------------------------------
wire [7:0] ram_addr;
wire [7:0] ram_rdata;

// ---------------------------------------------------------------------------
// Stack wires
// ---------------------------------------------------------------------------
wire [7:0] stack_data_out;
wire [7:0] stack_data_in;

// ---------------------------------------------------------------------------
// PRNG wire
// ---------------------------------------------------------------------------
wire [7:0] prng_data;

// ---------------------------------------------------------------------------
// Module instantiations
// ---------------------------------------------------------------------------

// --- Program ROM ---
rom #(.INIT_FILE(ROM_INIT)) u_rom (
    .clk      (clk),
    .addr     (pc_out),
    .data_out (rom_out)
);

// --- Instruction Decoder ---
decoder u_dec (
    .instr      (instr),
    .flag_z     (flag_z),
    .flag_c     (flag_c),
    .flag_n     (flag_n),
    .flag_v     (flag_v),
    .rd_addr    (dec_rd_addr),
    .ra_addr    (dec_ra_addr),
    .rb_addr    (dec_rb_addr),
    .reg_we     (dec_reg_we),
    .alu_op     (dec_alu_op),
    .alu_src_b  (dec_alu_src_b),
    .imm        (dec_imm),
    .wb_sel     (dec_wb_sel),
    .mem_re     (dec_mem_re),
    .mem_we     (dec_mem_we),
    .pc_load    (dec_pc_load),
    .pc_target  (dec_pc_target),
    .stack_push (dec_stack_push),
    .stack_pop  (dec_stack_pop),
    .flags_we   (dec_flags_we),
    .halt       (dec_halt)
);

// --- Register File ---
regfile u_rf (
    .clk     (clk),
    .rst     (rst),
    .we      (dec_reg_we),
    .rd_addr (dec_rd_addr),
    .ra_addr (dec_ra_addr),
    .rb_addr (dec_rb_addr),
    .rd_data (wb_data),
    .ra_data (ra_data),
    .rb_data (rb_data),
    .dbg_r7  (dbg_r7)
);

// --- ALU B-input mux: 0=Rb, 1=immediate ---
assign alu_b = dec_alu_src_b ? dec_imm : rb_data;

// --- ALU ---
alu u_alu (
    .op     (dec_alu_op),
    .a      (ra_data),
    .b      (alu_b),
    .result (alu_result),
    .z      (alu_z),
    .c      (alu_c),
    .n      (alu_n),
    .v      (alu_v)
);

// --- Data RAM ---
// Address comes from Ra (for LD) or Ra (for ST, addr_reg is in Ra field via decoder)
assign ram_addr = ra_data;

ram u_ram (
    .clk      (clk),
    .we       (dec_mem_we),
    .addr     (ram_addr),
    .data_in  (rb_data),    // ST stores rb_data at ra_data address
    .data_out (ram_rdata)
);

// --- Stack ---
// Push data mux: CALL pushes pc_out (the address after the CALL instruction);
// PUSH pushes ra_data.
//
// Why pc_out and not pc_next:
//   Because the ROM is synchronous, the instruction currently in the decode
//   stage was fetched when pc = pc_out - 1.  Therefore pc_out already points
//   one past the CALL instruction — it is the correct return address.
wire is_call = (instr[15:12] == 4'h5) && (instr[11:9] == 3'b010);
assign stack_data_in = is_call ? pc_out : ra_data;

stack u_stack (
    .clk       (clk),
    .rst       (rst),
    .push      (dec_stack_push),
    .pop       (dec_stack_pop),
    .data_in   (stack_data_in),
    .data_out  (stack_data_out),
    .full      (),
    .empty     (dbg_stack_empty),
    .overflow  (),
    .underflow ()
);

// --- Hardware PRNG ---
// Runs at the board clock rate (via prng_advance from top.v) so the value
// the CPU reads via IN is effectively unpredictable from software.
prng u_prng (
    .clk     (clk),
    .rst     (rst),
    .advance (prng_advance),
    .data    (prng_data)
);

// --- Write-back mux ---
// 3'b000 = ALU result
// 3'b001 = RAM read
// 3'b010 = immediate (LDI)
// 3'b011 = stack pop (POP/RET)
// 3'b100 = PRNG (IN)
assign wb_data = (dec_wb_sel == 3'b000) ? alu_result     :
                 (dec_wb_sel == 3'b001) ? ram_rdata      :
                 (dec_wb_sel == 3'b010) ? dec_imm        :
                 (dec_wb_sel == 3'b011) ? stack_data_out :
                                          prng_data;

// --- PC load-target mux ---
// JR:  pc_in = ra_data
// RET: pc_in = stack_data_out (top of stack before pop)
// else: pc_in = dec_pc_target (imm8)
wire is_jr  = (instr[15:12] == 4'h4) && (instr[11:9] == 3'b111);
wire is_ret = (instr[15:12] == 4'h5) && (instr[11:9] == 3'b011);

assign pc_in = is_jr  ? ra_data        :
               is_ret ? stack_data_out :
                        dec_pc_target;

// --- Program Counter ---
pc u_pc (
    .clk    (clk),
    .rst    (rst),
    .halt   (dec_halt | halted),   // hold PC during HALT and after
    .load   (dec_pc_load),
    .pc_in  (pc_in),
    .pc_out (pc_out),
    .pc_next(pc_next)
);

// --- Flag register (synchronous update) ---
always @(posedge clk) begin
    if (rst) begin
        flag_z <= 1'b0;
        flag_c <= 1'b0;
        flag_n <= 1'b0;
        flag_v <= 1'b0;
    end else if (dec_flags_we) begin
        flag_z <= alu_z;
        flag_c <= alu_c;
        flag_n <= alu_n;
        flag_v <= alu_v;
    end
end

// --- Halt output (asserted from first HALT cycle and held permanently) ---
assign halt_out = dec_halt | halted;

// --- Debug / LED output taps ---
assign dbg_pc     = pc_out;
assign dbg_flag_z = flag_z;
assign dbg_flag_c = flag_c;
assign dbg_flag_n = flag_n;
assign dbg_flag_v = flag_v;
// dbg_r7 is wired directly from regfile port
assign dbg_stack_top   = stack_data_out;
// dbg_stack_empty is wired directly from stack port

endmodule
