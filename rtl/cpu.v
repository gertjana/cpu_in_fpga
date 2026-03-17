// =============================================================================
// cpu.v — Top-level CPU (8-bit data path, 16-bit address space)
//
// Architecture: Harvard, single-issue, two-cycle fetch+execute pipeline.
//
// Pipeline timing:
//   Cycle N  : PC presented to ROM as fetch address
//   Cycle N+1: ROM output valid → decoder → datapath executes combinationally
//              → register / memory / stack / PC updated on rising edge of N+1
//
// Instruction formats, ISA and control signals are defined in decoder.v.
// All instructions are 24 bits wide.
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
    input  wire        clk,
    input  wire        rst,
    output wire        halt_out,

    // PRNG value sampled from the hardware LFSR in top.v (runs at 12 MHz).
    input  wire [7:0]  prng_data,

    // GPIO input pin values (sampled in top.v, passed as plain wire).
    input  wire [7:0]  gpio_data,

    // ADC sampled value (external, passed as plain wire from top.v).
    input  wire [7:0]  adc_data,

    // Peripheral write interface (OUT instruction).
    // Asserted for one cpu clk cycle; data is the source register value.
    output wire        periph_we,
    output wire [2:0]  periph_port,
    output wire [7:0]  periph_data,

    // Debug / LED outputs (combinational taps of internal state)
    output wire [7:0] dbg_pc,
    output wire       dbg_flag_z,
    output wire       dbg_flag_c,
    output wire       dbg_flag_n,
    output wire       dbg_flag_v,
    output wire [7:0] dbg_r0,
    output wire [7:0] dbg_r1,
    output wire [7:0] dbg_r2,
    output wire [7:0] dbg_r3,
    output wire [7:0] dbg_r4,
    output wire [7:0] dbg_r5,
    output wire [7:0] dbg_r6,
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
wire        dec_alu_cin;
wire [7:0]  dec_imm;
wire [2:0]  dec_wb_sel;
wire        dec_mem_re;
wire        dec_mem_we;
wire        dec_pc_load;
wire [15:0] dec_pc_target;
wire        dec_stack_push;
wire        dec_stack_pop;
wire        dec_flags_we;
wire        dec_halt;
wire        dec_periph_we;
wire [2:0]  dec_periph_port;

// ---------------------------------------------------------------------------
// Instruction register (ROM output) with branch-delay-slot flush and
// halt sticky latch.
//
// flush_r: inserted NOP cycle after every taken branch (ROM latency compensation)
// halted:  sticky flag — once HALT executes, all subsequent ROM outputs are
//          replaced with NOP and pc.halt is held permanently.
// ---------------------------------------------------------------------------
wire [23:0] rom_out;    // raw ROM output
reg         flush_r;   // 1 = suppress next instruction (replace with NOP)
reg         halted;    // 1 = CPU has executed HALT and is permanently frozen
wire [23:0] instr;     // instruction presented to decoder

// NOP encoding: group=0xE, all other bits 0 → 24'hE00000
assign instr = (flush_r || halted) ? 24'hE00000 : rom_out;

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
wire [15:0] pc_out;
wire [15:0] pc_next;
wire [15:0] pc_in;

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
wire [15:0] stack_data_out;
wire [15:0] stack_data_in;

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
    .alu_cin    (dec_alu_cin),
    .imm        (dec_imm),
    .wb_sel     (dec_wb_sel),
    .mem_re     (dec_mem_re),
    .mem_we     (dec_mem_we),
    .pc_load    (dec_pc_load),
    .pc_target  (dec_pc_target),
    .stack_push (dec_stack_push),
    .stack_pop  (dec_stack_pop),
    .flags_we   (dec_flags_we),
    .halt       (dec_halt),
    .periph_we  (dec_periph_we),
    .periph_port(dec_periph_port)
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
    .dbg_r0  (dbg_r0),
    .dbg_r1  (dbg_r1),
    .dbg_r2  (dbg_r2),
    .dbg_r3  (dbg_r3),
    .dbg_r4  (dbg_r4),
    .dbg_r5  (dbg_r5),
    .dbg_r6  (dbg_r6),
    .dbg_r7  (dbg_r7)
);

// --- ALU B-input mux: 0=Rb, 1=immediate ---
assign alu_b = dec_alu_src_b ? dec_imm : rb_data;

// --- ALU ---
alu u_alu (
    .op     (dec_alu_op),
    .a      (ra_data),
    .b      (alu_b),
    .cin    (dec_alu_cin & flag_c),   // 1 = ADC: route carry flag into adder
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
// PUSH pushes ra_data (zero-extended to 16 bits since registers are 8-bit).
//
// Why pc_out and not pc_next:
//   Because the ROM is synchronous, the instruction currently in the decode
//   stage was fetched when pc = pc_out - 1.  Therefore pc_out already points
//   one past the CALL instruction — it is the correct return address.
//
// is_call: group=0x5 (STK), sub-opcode=010 (CALL) — bits [23:20] and [19:17]
wire is_call = (instr[23:20] == 4'h5) && (instr[19:17] == 3'b010);
assign stack_data_in = is_call ? pc_out : {8'h00, ra_data};

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

// --- Write-back mux ---
// 3'b000 = ALU result
// 3'b001 = RAM read
// 3'b010 = immediate (LDI)
// 3'b011 = stack pop (POP/RET) — lower 8 bits only (PUSH zero-extends)
// 3'b100 = PRNG (IN port 1)
// 3'b101 = GPIO input (IN port 2)
// 3'b110 = ADC value (IN port 4)
assign wb_data = (dec_wb_sel == 3'b000) ? alu_result           :
                 (dec_wb_sel == 3'b001) ? ram_rdata             :
                 (dec_wb_sel == 3'b010) ? dec_imm               :
                 (dec_wb_sel == 3'b011) ? stack_data_out[7:0]   :
                 (dec_wb_sel == 3'b100) ? prng_data              :
                 (dec_wb_sel == 3'b101) ? gpio_data              :
                 (dec_wb_sel == 3'b110) ? adc_data               :
                                          8'h00;

// --- PC load-target mux ---
// JR:  pc_in = {8'h00, ra_data}  (register holds 8-bit address, zero-extend)
// RET: pc_in = stack_data_out (16-bit return address pushed by CALL)
// else: pc_in = dec_pc_target (addr16)
//
// is_jr:  group=0x4 (JMP), sub-opcode=111 (JR) — bits [23:20] and [19:17]
// is_ret: group=0x5 (STK), sub-opcode=011 (RET) — bits [23:20] and [19:17]
wire is_jr  = (instr[23:20] == 4'h4) && (instr[19:17] == 3'b111);
wire is_ret = (instr[23:20] == 4'h5) && (instr[19:17] == 3'b011);

assign pc_in = is_jr  ? {8'h00, ra_data}  :
               is_ret ? stack_data_out     :
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

// --- Peripheral write interface (OUT instruction) ---
// periph_data is the value of the source register (Ra field of OUT).
// ra_data is already read through the register file with ra_addr set by decoder.
assign periph_we   = dec_periph_we;
assign periph_port = dec_periph_port;
assign periph_data = ra_data;

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
