// =============================================================================
// decoder.v — Instruction Decoder (Control Unit)
//
// All instructions are 24 bits wide.
//
// Instruction formats:
//
//  R-format:   [23:20] group | [19:17] Rd/sub | [16:14] Ra | [13:11] Rb | [10:8] sub | [7:0] unused
//  I6-format:  [23:20] group | [19:17] Rd      | [16:14] Ra | [13:8] imm6             | [7:0] unused
//  I8-format:  [23:20] group | [19:17] Rd/sub  | [16:14] Ra |                           [7:0] imm8
//  I16-format: [23:20] group | [19:17] sub      | [18] unused |                         [15:0] addr16
//
// Field summary:
//   [23:20] group       — instruction group (4 bits)
//   [19:17] f_rd        — Rd / sub-opcode (3 bits)
//   [16:14] f_ra        — Ra (3 bits)
//   [13:11] f_rb        — Rb (3 bits)
//   [10:8]  f_sub       — sub field / Rb extra (3 bits)
//   [13:8]  f_imm6      — 6-bit immediate (I6-format: ADDI, CMPI)
//   [7:0]   f_imm8      — 8-bit immediate (I8-format: LDI)
//   [15:0]  f_addr16    — 16-bit address  (I16-format: JMP, Jcc, CALL)
//
// Groups:
//   4'h0  ALU reg-reg    sub-op in [2:0]
//   4'h1  ADDI           Rd = Ra + imm6   (I6-format)
//   4'h2  Mem            sub-op in [19:17] (mixed)
//          LDI: 0010 000 ddd xxxxxx iiiiiiii  (I8-format: dest=Ra field, imm8 in [7:0])
//          LD:  0010 001 ddd aaa xxxxxxxxxx   (R-format: dest=Ra field)
//          ST:  0010 010 xxx aaa bbb xxxxxxxx (R-format)
//   4'h3  MOV            Rd = Ra           (R-format)
//   4'h4  Jump/Branch    sub-op in [19:17] (I16/R)
//   4'h5  Stack/Call     sub-op in [19:17] (I16/R)
//   4'h6  CMP            Ra - Rb flags     (R-format)
//   4'h7  CMPI           Ra - imm6 flags   (I6-format)
//   4'h8  IN             Rd = peripheral[port]  (R-format)
//   4'h9  OUT            peripheral[port] = Ra  (R-format)
//   4'hE  NOP
//   4'hF  HALT
// =============================================================================

module decoder (
    // Instruction word (24-bit)
    input  wire [23:0] instr,

    // Current flags
    input  wire        flag_z,
    input  wire        flag_c,
    input  wire        flag_n,
    input  wire        flag_v,

    // Register file
    output reg  [2:0]  rd_addr,
    output reg  [2:0]  ra_addr,
    output reg  [2:0]  rb_addr,
    output reg         reg_we,

    // ALU
    output reg  [2:0]  alu_op,
    output reg         alu_src_b,  // 0=Rb, 1=immediate
    output reg  [7:0]  imm,        // immediate value (imm6 zero-ext or imm8)

    // Write-back source select
    // 3'b000 = ALU result
    // 3'b001 = data memory read
    // 3'b010 = immediate (LDI)
    // 3'b011 = stack pop
    // 3'b100 = PRNG   (IN port 1)
    // 3'b101 = GPIO   (IN port 2)
    // 3'b110 = ADC    (IN port 4)
    output reg  [2:0]  wb_sel,

    // Memory
    output reg         mem_re,
    output reg         mem_we,

    // PC control
    output reg         pc_load,
    output reg  [15:0] pc_target,

    // Stack
    output reg         stack_push,
    output reg         stack_pop,

    // Flags write enable
    output reg         flags_we,

    // Peripheral write (OUT instruction)
    output reg         periph_we,    // 1 = write to peripheral this cycle
    output reg  [2:0]  periph_port,  // which peripheral (port number)

    // CPU control
    output reg         halt
);

// ---------------------------------------------------------------------------
// Field extraction
// ---------------------------------------------------------------------------
wire [3:0] group = instr[23:20];

// R-format / I-format fields
wire [2:0] f_rd  = instr[19:17];   // sub-opcode or destination reg
wire [2:0] f_ra  = instr[16:14];   // source A reg or destination (mem/pop)
wire [2:0] f_rb  = instr[13:11];   // source B reg
wire [2:0] f_sub = instr[10:8];    // extra sub / source B

// Immediate values
wire [5:0]  f_imm6  = instr[13:8];    // I6-format: 6-bit immediate (ADDI, CMPI)
wire [7:0]  f_imm8  = instr[7:0];     // I8-format: 8-bit immediate (LDI)
wire [15:0] f_addr16 = instr[15:0];   // I16-format: 16-bit address (JMP, Jcc, CALL)

// ---------------------------------------------------------------------------
// Group constants
// ---------------------------------------------------------------------------
localparam GRP_ALU  = 4'h0;
localparam GRP_ADDI = 4'h1;
localparam GRP_MEM  = 4'h2;
localparam GRP_MOV  = 4'h3;
localparam GRP_JMP  = 4'h4;
localparam GRP_STK  = 4'h5;
localparam GRP_CMP  = 4'h6;
localparam GRP_CMPI = 4'h7;
localparam GRP_IN   = 4'h8;
localparam GRP_OUT  = 4'h9;
localparam GRP_NOP  = 4'hE;
localparam GRP_HALT = 4'hF;

// Memory sub-opcodes — in Rd field [19:17] for Group 2
localparam MEM_LDI = 3'b000;
localparam MEM_LD  = 3'b001;
localparam MEM_ST  = 3'b010;

// Jump sub-opcodes (in Rd field [19:17])
localparam JMP_JMP = 3'b000;
localparam JMP_JZ  = 3'b001;
localparam JMP_JNZ = 3'b010;
localparam JMP_JC  = 3'b011;
localparam JMP_JNC = 3'b100;
localparam JMP_JN  = 3'b101;
localparam JMP_JV  = 3'b110;
localparam JMP_JR  = 3'b111;

// Stack sub-opcodes (in Rd field [19:17])
localparam STK_PUSH = 3'b000;
localparam STK_POP  = 3'b001;
localparam STK_CALL = 3'b010;
localparam STK_RET  = 3'b011;

// ALU op codes (must match alu.v)
localparam ALU_ADD = 3'b000;
localparam ALU_SUB = 3'b001;
localparam ALU_AND = 3'b010;
localparam ALU_OR  = 3'b011;
localparam ALU_XOR = 3'b100;
localparam ALU_NOT = 3'b101;
localparam ALU_SHL = 3'b110;
localparam ALU_SHR = 3'b111;

// Write-back select
localparam WB_ALU   = 3'b000;
localparam WB_MEM   = 3'b001;
localparam WB_IMM   = 3'b010;
localparam WB_STACK = 3'b011;
localparam WB_PRNG  = 3'b100;
localparam WB_GPIO  = 3'b101;   // IN port 2 — GPIO pin values
localparam WB_ADC   = 3'b110;   // IN port 4 — ADC sampled value

// ---------------------------------------------------------------------------
// Branch condition evaluation (combinational)
// ---------------------------------------------------------------------------
reg branch_taken;

always @(*) begin
    case (f_rd)   // jump sub-opcode lives in [19:17]
        JMP_JMP: branch_taken = 1'b1;
        JMP_JZ:  branch_taken =  flag_z;
        JMP_JNZ: branch_taken = ~flag_z;
        JMP_JC:  branch_taken =  flag_c;
        JMP_JNC: branch_taken = ~flag_c;
        JMP_JN:  branch_taken =  flag_n;
        JMP_JV:  branch_taken =  flag_v;
        JMP_JR:  branch_taken = 1'b1;
        default: branch_taken = 1'b0;
    endcase
end

// ---------------------------------------------------------------------------
// Main decode (purely combinational)
// ---------------------------------------------------------------------------
always @(*) begin
    // Safe defaults — no side effects
    rd_addr    = f_rd;
    ra_addr    = f_ra;
    rb_addr    = f_rb;
    reg_we     = 1'b0;
    alu_op     = ALU_ADD;
    alu_src_b  = 1'b0;
    imm        = 8'h00;
    wb_sel     = WB_ALU;
    mem_re     = 1'b0;
    mem_we     = 1'b0;
    pc_load    = 1'b0;
    pc_target  = f_addr16;
    stack_push = 1'b0;
    stack_pop  = 1'b0;
    flags_we   = 1'b0;
    halt       = 1'b0;
    periph_we  = 1'b0;
    periph_port = 3'b000;

    case (group)

        // ------------------------------------------------------------------
        // Group 0: ALU reg-reg
        // R-format: 0000 sss ddd aaa bbb xxx 00000000
        //   [19:17] sub-opcode (ALU op)
        //   [16:14] Rd (destination)
        //   [13:11] Ra (source A)
        //   [10:8]  Rb (source B)
        // ------------------------------------------------------------------
        GRP_ALU: begin
            rd_addr   = f_ra;      // destination reg in [16:14]
            ra_addr   = f_rb;      // source A reg   in [13:11]
            rb_addr   = f_sub;     // source B reg   in [10:8]
            alu_op    = f_rd;      // sub-opcode     in [19:17]
            alu_src_b = 1'b0;
            reg_we    = 1'b1;
            wb_sel    = WB_ALU;
            flags_we  = 1'b1;
        end

        // ------------------------------------------------------------------
        // Group 1: ADDI — Rd = Ra + imm6
        // I6-format: 0001 ddd aaa iiiiii 00000000
        //   [19:17] Rd
        //   [16:14] Ra
        //   [13:8]  imm6
        // ------------------------------------------------------------------
        GRP_ADDI: begin
            rd_addr   = f_rd;
            ra_addr   = f_ra;
            alu_op    = ALU_ADD;
            alu_src_b = 1'b1;
            imm       = {2'b00, f_imm6};   // zero-extend imm6 to 8 bits
            reg_we    = 1'b1;
            wb_sel    = WB_ALU;
            flags_we  = 1'b1;
        end

        // ------------------------------------------------------------------
        // Group 2: Memory — sub-op in Rd field [19:17]
        //   LDI: 0010 000 ddd xxxxxx iiiiiiii  Rd in Ra field [16:14], imm8 in [7:0]
        //   LD:  0010 001 ddd aaa xxxxxxxxxx   Rd in Ra field [16:14], addr in Rb field [13:11]
        //   ST:  0010 010 xxx aaa bbb xxxxxxxx addr in Rb field [13:11], data in sub [10:8]
        // ------------------------------------------------------------------
        GRP_MEM: begin
            case (f_rd)   // sub-opcode in Rd field [19:17]

                MEM_LDI: begin
                    // LDI Rd, imm8: destination in Ra field [16:14], imm8 in [7:0]
                    // Encoding: 0010 000 ddd xxxxxx iiiiiiii
                    rd_addr = f_ra;
                    imm     = f_imm8;
                    reg_we  = 1'b1;
                    wb_sel  = WB_IMM;
                end

                MEM_LD: begin
                    // LD Rd, [Ra_src]: dest in Ra field [16:14], addr in Rb field [13:11]
                    rd_addr = f_ra;
                    ra_addr = f_rb;
                    mem_re  = 1'b1;
                    reg_we  = 1'b1;
                    wb_sel  = WB_MEM;
                end

                MEM_ST: begin
                    // ST [addr_reg], data_reg
                    // addr in Rb field [13:11], data in sub field [10:8]
                    ra_addr = f_rb;
                    rb_addr = f_sub;
                    mem_we  = 1'b1;
                end

                default: ; // undefined sub-op — NOP
            endcase
        end

        // ------------------------------------------------------------------
        // Group 3: MOV — Rd = Ra
        // R-format: 0011 ddd aaa 000000000000000
        // Implemented as Ra OR 0x00 through the ALU
        // ------------------------------------------------------------------
        GRP_MOV: begin
            rd_addr   = f_rd;
            ra_addr   = f_ra;
            alu_op    = ALU_OR;
            alu_src_b = 1'b1;
            imm       = 8'h00;
            reg_we    = 1'b1;
            wb_sel    = WB_ALU;
            // flags NOT updated by MOV
        end

        // ------------------------------------------------------------------
        // Group 4: Jump / Branch
        // I16-format: 0100 sub x aaaaaaaaaaaaaaaa   (JMP/Jcc — addr16 in [15:0])
        // R-format:   0100 111 aaa 00000000000000000 (JR — Ra in [16:14])
        // ------------------------------------------------------------------
        GRP_JMP: begin
            if (f_rd == JMP_JR) begin
                // Indirect jump: PC = Ra
                ra_addr   = f_ra;
                pc_load   = 1'b1;       // target muxed in CPU top-level from Ra
                pc_target = f_addr16;   // overridden by top-level for JR
            end else begin
                pc_load   = branch_taken;
                pc_target = f_addr16;
            end
        end

        // ------------------------------------------------------------------
        // Group 5: Stack / Subroutines
        // ------------------------------------------------------------------
        GRP_STK: begin
            case (f_rd)

                STK_PUSH: begin
                    // PUSH Ra: 0101 000 aaa 000000000000000
                    ra_addr    = f_ra;
                    stack_push = 1'b1;
                end

                STK_POP: begin
                    // POP Rd: 0101 001 ddd 000000000000000
                    rd_addr   = f_ra;   // destination in Ra field for POP
                    stack_pop = 1'b1;
                    reg_we    = 1'b1;
                    wb_sel    = WB_STACK;
                end

                STK_CALL: begin
                    // CALL addr16: 0101 010 x aaaaaaaaaaaaaaaa
                    stack_push = 1'b1;  // pushes pc_next from CPU top-level
                    pc_load    = 1'b1;
                    pc_target  = f_addr16;
                end

                STK_RET: begin
                    // RET: 0101 011 000 000000000000000
                    stack_pop = 1'b1;
                    pc_load   = 1'b1;   // target comes from stack in top-level
                end

                default: ; // undefined — NOP
            endcase
        end

        // ------------------------------------------------------------------
        // Group 6: CMP Ra, Rb — flags from Ra - Rb, no write
        // R-format: 0110 000 aaa bbb 00000000000
        //   [16:14] Ra
        //   [13:11] Rb
        // ------------------------------------------------------------------
        GRP_CMP: begin
            ra_addr   = f_ra;
            rb_addr   = f_rb;
            alu_op    = ALU_SUB;
            alu_src_b = 1'b0;
            flags_we  = 1'b1;
            reg_we    = 1'b0;
        end

        // ------------------------------------------------------------------
        // Group 7: CMPI Ra, imm6 — flags from Ra - imm6, no write
        // I6-format: 0111 000 aaa iiiiii 00000000
        //   [16:14] Ra
        //   [13:8]  imm6
        // ------------------------------------------------------------------
        GRP_CMPI: begin
            ra_addr   = f_ra;
            alu_op    = ALU_SUB;
            alu_src_b = 1'b1;
            imm       = {2'b00, f_imm6};
            flags_we  = 1'b1;
            reg_we    = 1'b0;
        end

        // ------------------------------------------------------------------
        // Group 8: IN Rd, port — read hardware peripheral into register
        // R-format: 1000 ddd ppp 000000000000000
        //   [19:17] Rd   — destination register
        //   [16:14] port — peripheral select
        //     3'b001 = PRNG data
        //     3'b010 = GPIO input pin values
        //     3'b011 = GPIO direction (read-back, not implemented — NOP)
        //     3'b100 = ADC sampled value
        // Undefined port numbers are treated as NOP.
        // ------------------------------------------------------------------
        GRP_IN: begin
            case (f_ra)   // port number in Ra field [16:14]
                3'b001: begin   // port 1 = PRNG
                    rd_addr = f_rd;
                    reg_we  = 1'b1;
                    wb_sel  = WB_PRNG;
                end
                3'b010: begin   // port 2 = GPIO input
                    rd_addr = f_rd;
                    reg_we  = 1'b1;
                    wb_sel  = WB_GPIO;
                end
                3'b011: begin   // port 3 = GPIO direction (write-only, IN not supported — NOP)
                    ; // fall through to default
                end
                3'b100: begin   // port 4 = ADC value
                    rd_addr = f_rd;
                    reg_we  = 1'b1;
                    wb_sel  = WB_ADC;
                end
                default: ; // unknown port — NOP
            endcase
        end

        // ------------------------------------------------------------------
        // Group 9: OUT Ra, port — write register value to hardware peripheral
        // R-format: 1001 aaa ppp 000000000000000
        //   [19:17] Ra   — source register (value to write)
        //   [16:14] port — peripheral select
        //     3'b001 = PRNG seed (reseed the LFSR)
        //     3'b010 = GPIO output register (8 digital output pins)
        //     3'b011 = GPIO direction register (1=output, 0=input)
        // Undefined port numbers (including 4–7) are treated as NOP.
        // ------------------------------------------------------------------
        GRP_OUT: begin
            case (f_ra)   // port number in Ra field [16:14]
                3'b001,   // port 1 = PRNG seed
                3'b010,   // port 2 = GPIO out
                3'b011: begin  // port 3 = GPIO direction
                    ra_addr    = f_rd;   // source register is in [19:17]
                    periph_we  = 1'b1;
                    periph_port = f_ra;
                end
                default: ; // unknown port — NOP
            endcase
        end

        // ------------------------------------------------------------------
        // Group 14: NOP
        // ------------------------------------------------------------------
        GRP_NOP: begin
            // all defaults — no side effects
        end

        // ------------------------------------------------------------------
        // Group 15: HALT
        // ------------------------------------------------------------------
        GRP_HALT: begin
            halt = 1'b1;
        end

        default: begin
            // undefined group — treat as NOP
        end

    endcase
end

endmodule
