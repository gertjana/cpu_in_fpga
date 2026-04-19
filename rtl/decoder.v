// =============================================================================
// decoder.v — Instruction Decoder (Control Unit)
//
// All instructions are 24 bits wide.
//
// Instruction formats:
//
//  R-format:   [23:20] group | [19:17] Rd/sub | [16:14] Ra | [13:11] Rb | [10:8] sub | [7:0] unused
//  I8-format:  [23:20] group | [19:17] Rd/sub  | [16:14] Ra | [13:8] unused |           [7:0] imm8
//  I16-format: [23:20] group | [19:17] sub      | [18] unused |                         [15:0] addr16
//  IN/OUT:     [23:20] group | [19:17] Rd/Ra    | [16:13] pppp (4-bit port) | [12:0] unused
//
// All instructions that take an immediate use the last byte [7:0] for the immediate value.
// This is consistent across LDI, ADDI, and CMPI (all use imm8 in [7:0]; range 0–255).
//
// ALU group (0) uses an extended 4-bit sub-opcode field — field positions
// differ from all other groups:
//
//  ALU:        [23:20] group | [19:16] alu_op(4b) | [15:13] Rd | [12:10] Ra | [9:7] Rb | [6:0] unused
//
//   alu_op[2:0] selects the ALU operation (same codes as before).
//   alu_op[3]   is the carry-in enable bit: when set, ADD becomes ADC
//               (a + b + flag_c).  This gives 8 carry-capable variants:
//                 0b1000 ADC — add with carry
//                 0b1001 SBC — subtract with borrow (reserved, not yet used)
//                 0b1010..0b1111 — reserved
//
// Field summary (non-ALU groups):
//   [23:20] group       — instruction group (4 bits)
//   [19:17] f_rd        — Rd / sub-opcode (3 bits)
//   [16:14] f_ra        — Ra (3 bits)
//   [13:11] f_rb        — Rb (3 bits)
//   [10:8]  f_sub       — sub field / Rb extra (3 bits)
//   [13:8]  unused      — (formerly imm6; now reserved / zero for ADDI and CMPI)
//   [7:0]   f_imm8      — 8-bit immediate (I8-format: LDI, ADDI, CMPI)
//   [15:0]  f_addr16    — 16-bit address  (I16-format: JMP, Jcc, CALL)
//
// Groups:
//   4'h0  ALU reg-reg    4-bit sub-op in [19:16]; Rd/Ra/Rb in [15:13]/[12:10]/[9:7]
//   4'h1  ADDI           Rd = Ra + imm8   (I8-format)
//   4'h2  Mem            sub-op in [19:17] (mixed)
//          LDI: 0010 000 ddd xxxxxx iiiiiiii  (I8-format: dest=Ra field, imm8 in [7:0])
//          LD:  0010 001 ddd aaa xxxxxxxxxx   (R-format: dest=Ra field)
//          ST:  0010 010 xxx aaa bbb xxxxxxxx (R-format)
//   4'h3  MOV            Rd = Ra           (R-format)
//   4'h4  Jump/Branch    sub-op in [19:17] (I16/R)
//   4'h5  Stack/Call     sub-op in [19:17] (I16/R)
//   4'h6  CMP            Ra - Rb flags     (R-format)
//   4'h7  CMPI           Ra - imm8 flags   (I8-format)
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
    output reg         alu_cin,    // 1=carry-in enabled (ADC); 0=normal ADD
    output reg  [7:0]  imm,        // immediate value (imm8)

    // Write-back source select
    // 3'b000 = ALU result
     // 3'b001 = data memory read
     // 3'b010 = immediate (LDI)
     // 3'b011 = stack pop
     // 3'b100 = PRNG   (IN port 1)
     // 3'b101 = GPIO   (IN port 5)
     // 3'b110 = ADC    (IN port 3)
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
    output reg  [3:0]  periph_port,  // which peripheral (port number, 0–15)

    // CPU control
    output reg         halt
);

// ---------------------------------------------------------------------------
// Field extraction
// ---------------------------------------------------------------------------
wire [3:0] group = instr[23:20];

// Standard R-format / I-format fields (used by all groups except ALU)
wire [2:0] f_rd  = instr[19:17];   // sub-opcode or destination reg
wire [2:0] f_ra  = instr[16:14];   // source A reg or destination (mem/pop)
wire [2:0] f_rb  = instr[13:11];   // source B reg
wire [2:0] f_sub = instr[10:8];    // extra sub / source B

// ALU group (0) extended fields — 4-bit op, register fields shifted down 1 bit
wire [3:0] f_alu_op = instr[19:16]; // 4-bit ALU sub-opcode
wire [2:0] f_alu_rd = instr[15:13]; // Rd for ALU instructions
wire [2:0] f_alu_ra = instr[12:10]; // Ra for ALU instructions
wire [2:0] f_alu_rb = instr[9:7];   // Rb for ALU instructions

// Immediate values
wire [7:0]  f_imm8  = instr[7:0];     // I8-format: 8-bit immediate (LDI, ADDI, CMPI)
wire [15:0] f_addr16 = instr[15:0];   // I16-format: 16-bit address (JMP, Jcc, CALL)

// IN/OUT port field — 4 bits at [16:13], giving 16 addressable peripheral ports.
// Bit 13 is not globally unused; it is repurposed here because in the IN/OUT
// encoding, bits [13:0] were previously zero/reserved when group = 8/9.
wire [3:0]  f_port  = instr[16:13];   // IN/OUT peripheral port select (0–15)

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
localparam WB_GPIO  = 3'b101;   // IN port 5 — GPIO data read
localparam WB_ADC   = 3'b110;   // IN port 3 — ADC sampled value

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
        alu_cin    = 1'b0;
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
    periph_port = 4'b0000;

    case (group)

        // ------------------------------------------------------------------
        // Group 0: ALU reg-reg  (4-bit sub-opcode)
        // ALU-format: 0000 ssss ddd aaa bbb 0000000
        //   [19:16] ALU sub-opcode (4 bits); bit[3]=carry-in enable
        //   [15:13] Rd (destination)
        //   [12:10] Ra (source A)
        //   [9:7]   Rb (source B)
        //
        // alu_op  = f_alu_op[2:0]  — selects ADD/SUB/AND/OR/XOR/NOT/SHL/SHR
        // alu_cin = f_alu_op[3]    — 1 routes flag_c into ALU carry-in (ADC)
        // ------------------------------------------------------------------
        GRP_ALU: begin
            rd_addr   = f_alu_rd;
            ra_addr   = f_alu_ra;
            rb_addr   = f_alu_rb;
            alu_op    = f_alu_op[2:0];
            alu_cin   = f_alu_op[3];
            alu_src_b = 1'b0;
            reg_we    = 1'b1;
            wb_sel    = WB_ALU;
            flags_we  = 1'b1;
        end

        // ------------------------------------------------------------------
        // Group 1: ADDI — Rd = Ra + imm8
        // I8-format: 0001 ddd aaa xxxxxx iiiiiiii
        //   [19:17] Rd
        //   [16:14] Ra
        //   [13:8]  unused
        //   [7:0]   imm8
        // ------------------------------------------------------------------
        GRP_ADDI: begin
            rd_addr   = f_rd;
            ra_addr   = f_ra;
            alu_op    = ALU_ADD;
            alu_src_b = 1'b1;
            imm       = f_imm8;
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
        // Group 7: CMPI Ra, imm8 — flags from Ra - imm8, no write
        // I8-format: 0111 xxx aaa xxxxxx iiiiiiii
        //   [16:14] Ra
        //   [13:8]  unused
        //   [7:0]   imm8
        // ------------------------------------------------------------------
        GRP_CMPI: begin
            ra_addr   = f_ra;
            alu_op    = ALU_SUB;
            alu_src_b = 1'b1;
            imm       = f_imm8;
            flags_we  = 1'b1;
            reg_we    = 1'b0;
        end

        // ------------------------------------------------------------------
        // Group 8: IN Rd, port — read hardware peripheral into register
        // Format: 1000 ddd pppp 0000000000000
        //   [19:17] Rd   — destination register
        //   [16:13] port — peripheral select (4-bit, 0–15)
        //     4'd1 = PRNG data
        //     4'd2 = onboard LEDs (write-only — NOP)
        //     4'd3 = ADC sampled value
        //     4'd4 = GPIO direction (write-only — NOP)
        //     4'd5 = GPIO data (read pin levels)
        //     4'd6–4'd15 = reserved / not yet implemented — NOP
        // Undefined port numbers are treated as NOP.
        // ------------------------------------------------------------------
        GRP_IN: begin
            case (f_port)   // port number in bits [16:13]
                4'd1: begin   // port 1 = PRNG
                    rd_addr = f_rd;
                    reg_we  = 1'b1;
                    wb_sel  = WB_PRNG;
                end
                4'd2: begin   // port 2 = onboard LEDs (write-only, IN not supported — NOP)
                    ; // fall through to default
                end
                4'd3: begin   // port 3 = ADC value
                    rd_addr = f_rd;
                    reg_we  = 1'b1;
                    wb_sel  = WB_ADC;
                end
                4'd4: begin   // port 4 = GPIO direction (write-only, IN not supported — NOP)
                    ; // fall through to default
                end
                4'd5: begin   // port 5 = GPIO data (read pin levels)
                    rd_addr = f_rd;
                    reg_we  = 1'b1;
                    wb_sel  = WB_GPIO;
                end
                // ports 6–15: reserved / not yet implemented — NOP
                default: ; // unknown port — NOP
            endcase
        end

        // ------------------------------------------------------------------
        // Group 9: OUT Ra, port — write register value to hardware peripheral
        // Format: 1001 aaa pppp 0000000000000
        //   [19:17] Ra   — source register (value to write)
        //   [16:13] port — peripheral select (4-bit, 0–15)
        //     4'd1 = PRNG seed (reseed the LFSR)
        //     4'd2 = onboard LEDs
        //     4'd3 = ADC (read-only — NOP)
        //     4'd4 = GPIO direction register (1=output, 0=input)
        //     4'd5 = GPIO data register (output pin values)
        //     4'd6–4'd15 = reserved / not yet implemented — NOP
        // Undefined port numbers are treated as NOP.
        // ------------------------------------------------------------------
        GRP_OUT: begin
            case (f_port)   // port number in bits [16:13]
                4'd1,   // port 1 = PRNG seed
                4'd2,   // port 2 = onboard LEDs
                4'd4,   // port 4 = GPIO direction register (1=output, 0=input)
                4'd5: begin  // port 5 = GPIO data register (output pin values)
                    ra_addr    = f_rd;   // source register is in [19:17]
                    periph_we  = 1'b1;
                    periph_port = f_port;
                end
                // port 3 = ADC read-only; ports 6–15 reserved — NOP
                default: ; // unknown / reserved port — NOP
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
