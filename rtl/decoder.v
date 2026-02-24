// =============================================================================
// decoder.v — Instruction Decoder (Control Unit)
//
// Instruction formats (all 16-bit fixed width):
//
//  R-format:  [15:12] group | [11:9] Rd | [8:6] Ra | [5:3] Rb | [2:0] sub
//  I-format:  [15:12] group | [11:9] Rd | [8:6] Ra | [5:0] imm6
//  I8-format: [15:12] group | [11:9] Rd/sub | [8] unused | [7:0] imm8
//
// Groups:
//   4'h0  ALU reg-reg    sub-op in [2:0]
//   4'h1  ADDI           Rd = Ra + imm6   (I-format)
//   4'h2  Mem            sub-op in [11:9] (mixed)
//          LDI: 0010 000 ddd iiiiii  (I-format: dest in Ra field [8:6], imm6)
//          LD:  0010 001 ddd aaa xxx (R-format: dest in Ra field [8:6])
//          ST:  0010 010 xxx aaa bbb (R-format: addr in Rb [5:3], data in sub [2:0])
//   4'h3  MOV            Rd = Ra          (R-format)
//   4'h4  Jump/Branch    sub-op in [11:9] (I8/R)
//   4'h5  Stack/Call     sub-op in [11:9] (I8/R)
//   4'h6  CMP            Ra - Rb flags    (R-format)
//   4'h7  CMPI           Ra - imm6 flags  (I-format)
//   4'hE  NOP
//   4'hF  HALT
// =============================================================================

module decoder (
    // Instruction word
    input  wire [15:0] instr,

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
    // 2'b00 = ALU result
    // 2'b01 = data memory read
    // 2'b10 = immediate (LDI)
    // 2'b11 = stack pop
    output reg  [1:0]  wb_sel,

    // Memory
    output reg         mem_re,
    output reg         mem_we,

    // PC control
    output reg         pc_load,
    output reg  [7:0]  pc_target,

    // Stack
    output reg         stack_push,
    output reg         stack_pop,

    // Flags write enable
    output reg         flags_we,

    // CPU control
    output reg         halt
);

// ---------------------------------------------------------------------------
// Field extraction
// ---------------------------------------------------------------------------
wire [3:0] group = instr[15:12];

// R-format / I-format fields
wire [2:0] f_rd  = instr[11:9];   // destination reg or sub-opcode
wire [2:0] f_ra  = instr[8:6];    // source A reg or sub-opcode (mem)
wire [2:0] f_rb  = instr[5:3];    // source B reg
wire [2:0] f_sub = instr[2:0];    // ALU sub-opcode (group 0)

// Immediate values
wire [5:0] f_imm6 = instr[5:0];   // I-format:  6-bit immediate
wire [7:0] f_imm8 = instr[7:0];   // I8-format: 8-bit immediate

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
localparam GRP_NOP  = 4'hE;
localparam GRP_HALT = 4'hF;

// Memory sub-opcodes — in Rd field [11:9] for Group 2
localparam MEM_LDI = 3'b000;
localparam MEM_LD  = 3'b001;
localparam MEM_ST  = 3'b010;

// Jump sub-opcodes (in Rd field [11:9])
localparam JMP_JMP = 3'b000;
localparam JMP_JZ  = 3'b001;
localparam JMP_JNZ = 3'b010;
localparam JMP_JC  = 3'b011;
localparam JMP_JNC = 3'b100;
localparam JMP_JN  = 3'b101;
localparam JMP_JV  = 3'b110;
localparam JMP_JR  = 3'b111;

// Stack sub-opcodes (in Rd field [11:9])
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
localparam WB_ALU   = 2'b00;
localparam WB_MEM   = 2'b01;
localparam WB_IMM   = 2'b10;
localparam WB_STACK = 2'b11;

// ---------------------------------------------------------------------------
// Branch condition evaluation (combinational)
// ---------------------------------------------------------------------------
reg branch_taken;

always @(*) begin
    case (f_rd)   // jump sub-opcode lives in [11:9]
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
    pc_target  = f_imm8;
    stack_push = 1'b0;
    stack_pop  = 1'b0;
    flags_we   = 1'b0;
    halt       = 1'b0;

    case (group)

        // ------------------------------------------------------------------
        // Group 0: ALU reg-reg
        // R-format: 0000 ddd aaa bbb sss
        // ------------------------------------------------------------------
        GRP_ALU: begin
            rd_addr   = f_rd;
            ra_addr   = f_ra;
            rb_addr   = f_rb;
            alu_op    = f_sub;     // sub-opcode in [2:0]
            alu_src_b = 1'b0;
            reg_we    = 1'b1;
            wb_sel    = WB_ALU;
            flags_we  = 1'b1;
        end

        // ------------------------------------------------------------------
        // Group 1: ADDI — Rd = Ra + imm6
        // I-format: 0001 ddd aaa iiiiii
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
        // Group 2: Memory — sub-op in Rd field [11:9]
        //   LDI: 0010 000 ddd iiiiii  Rd in Ra field [8:6], imm6 in [5:0]
        //   LD:  0010 001 ddd aaa xxx  Rd in Ra field [8:6], addr in Rb field [5:3]
        //   ST:  0010 010 xxx aaa bbb  addr in Rb field [5:3], data in sub field [2:0]
        // ------------------------------------------------------------------
        GRP_MEM: begin
            case (f_rd)   // sub-opcode in Rd field [11:9]

                MEM_LDI: begin
                    // LDI: destination register in Ra field [8:6], imm6 in [5:0]
                    // Encoding: 0010 000 ddd iiiiii
                    rd_addr = f_ra;
                    imm     = {2'b00, f_imm6};
                    reg_we  = 1'b1;
                    wb_sel  = WB_IMM;
                end

                MEM_LD: begin
                    // LD Rd, [Ra_src]: dest in Ra field [8:6], addr in Rb field [5:3]
                    rd_addr = f_ra;
                    ra_addr = f_rb;
                    mem_re  = 1'b1;
                    reg_we  = 1'b1;
                    wb_sel  = WB_MEM;
                end

                MEM_ST: begin
                    // ST [addr_reg], data_reg
                    // addr in Rb field [5:3], data in sub field [2:0]
                    ra_addr = f_rb;
                    rb_addr = f_sub;
                    mem_we  = 1'b1;
                end

                default: ; // undefined sub-op — NOP
            endcase
        end

        // ------------------------------------------------------------------
        // Group 3: MOV — Rd = Ra
        // R-format: 0011 ddd aaa xxxxxxxxx
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
        // I8-format: 0100 sub x iiiiiiii   (JMP/Jcc)
        // R-format:  0100 111 aaa xxxxxxxx  (JR)
        // ------------------------------------------------------------------
        GRP_JMP: begin
            if (f_rd == JMP_JR) begin
                // Indirect jump: PC = Ra
                ra_addr   = f_ra;
                pc_load   = 1'b1;       // target muxed in CPU top-level from Ra
                pc_target = f_imm8;     // overridden by top-level for JR
            end else begin
                pc_load   = branch_taken;
                pc_target = f_imm8;
            end
        end

        // ------------------------------------------------------------------
        // Group 5: Stack / Subroutines
        // ------------------------------------------------------------------
        GRP_STK: begin
            case (f_rd)

                STK_PUSH: begin
                    // PUSH Ra: 0101 000 aaa xxxxxxxxx
                    ra_addr    = f_ra;
                    stack_push = 1'b1;
                end

                STK_POP: begin
                    // POP Rd: 0101 001 ddd xxxxxxxxx
                    rd_addr   = f_ra;   // destination in Ra field for POP
                    stack_pop = 1'b1;
                    reg_we    = 1'b1;
                    wb_sel    = WB_STACK;
                end

                STK_CALL: begin
                    // CALL imm8: 0101 010 x iiiiiiii
                    stack_push = 1'b1;  // pushes pc_next from CPU top-level
                    pc_load    = 1'b1;
                    pc_target  = f_imm8;
                end

                STK_RET: begin
                    // RET: 0101 011 xxx xxxxxxxxx
                    stack_pop = 1'b1;
                    pc_load   = 1'b1;   // target comes from stack in top-level
                end

                default: ; // undefined — NOP
            endcase
        end

        // ------------------------------------------------------------------
        // Group 6: CMP Ra, Rb — flags from Ra - Rb, no write
        // R-format: 0110 xxx aaa bbb xxx
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
        // I-format: 0111 xxx aaa iiiiii
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
