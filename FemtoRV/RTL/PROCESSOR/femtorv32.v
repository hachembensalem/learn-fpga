// femtorv32, a minimalistic RISC-V RV32I core 
//   (minus SYSTEM and FENCE that are not implemented)
// Bruno Levy, May-June 2020
//
// For more information, see README.md

/*******************************************************************/

`include "utils.v"                 // Utilities, macros for debugging
`include "register_file.v"         // The 31 general-purpose registers
`include "small_alu.v"             // Used on IceStick, RV32I   
`include "large_alu.v"             // For larger FPGAs, RV32IM
`include "branch_predicates.v"     // Tests for branch instructions
`include "decoder.v"               // The instruction decoder
`include "aligned_memory_access.v" // R/W bytes, hwords and words from memory
`include "CSR_file.v"              // (Optional) Control and Status registers 

/********************* Nrv processor *******************************/

module FemtoRV32 #(
  parameter [0:0] RV32M              = 0, // Set to 1 to support mul/div/rem
  parameter       ADDR_WIDTH         = 16 // width of the address bus
) (
   input 	     clk,

   output [31:0]      mem_addr,  // address bus, only ADDR_WIDTH bits are used
   output wire [31:0] mem_wdata, // data to be written
   output wire [3:0]  mem_wmask, // write mask for the 4 bytes of each word
   input [31:0]       mem_rdata, // input lines for both data and instr
   output wire 	      mem_rstrb, // active to initiate memory read (used by IO)
   input wire 	      mem_rbusy, // asserted if memory is busy reading value
   input wire         mem_wbusy, // asserted if memory is busy writing value
   
   input wire 	     reset, // set to 0 to reset the processor
   output wire 	     error  // 1 if current instruction could not be decoded
);


   // The internal register that stores the current address,
   // directly wired to the address bus.
   reg [ADDR_WIDTH-1:0] addressReg;
   assign mem_addr = addressReg;
   
   // The program counter (not storing the two LSBs, always aligned)
   reg [ADDR_WIDTH-3:0] PC;

   // The write data register, directly wired to the outgoing data bus.
   reg [31:0] wdataReg;
   assign mem_wdata = wdataReg;
   
   reg [31:0] instr;     // Latched instruction. 
   reg [31:0] nextInstr; // Prefetched instruction.

 
   // Next program counter in normal operation: advance one word
   // I do not use the ALU, I create an additional adder for that.
   // (not that the two LSBs are not stored, always aligned).
   wire [ADDR_WIDTH-3:0] PCplus4 = PC + 1;

   /***************************************************************************/
   // Instruction decoding.
   
   // Internal signals, generated by the decoder from the current instruction.
   
   wire [4:0] 	 writeBackRegId; // The register to be written back
   wire 	 writeBackEn;    // Needs to be asserted for writing back to reg.
   wire          writeBackALU;     // \
   wire          writeBackAplusB;  //  | data source for register write-back (if
   wire          writeBackPCplus4; //  | register write-back is enabled)
   wire          writeBackCSR;     // /
   wire [4:0] 	 regId1;       // Register output 1
   wire [4:0] 	 regId2;       // Register output 2
   
   wire 	 aluInSel1;    // 0: register  1: pc
   wire 	 aluInSel2;    // 0: register  1: imm
   wire [2:0] 	 func;         // operation done by the ALU, tests, load/store mode
   wire 	 funcQual;     // 'qualifier' used by some operations (+/-, logic/arith shifts)
   wire          funcM;        // asserted if instr is RV32M.
   wire [31:0] 	 imm;          // immediate value decoded from the instruction
   wire          needWaitALU;  // asserted if instruction uses at least 1  cycle in ALU
   
   wire          isALU;        // \
   wire 	 isLoad;       // | 
   wire 	 isStore;      // ) guess what !
   wire          isBranch;     // |
   wire          isJump;       // /
   
   wire          decoderError; // true if instr has invalid opcode

   // The instruction decoder, that reads the current instruction 
   // and generates all the signals from it. It is in fact just a
   // big combinatorial function.
   NrvDecoder decoder(
     .instr(instr),		     
     .writeBackRegId(writeBackRegId),
     .writeBackEn(writeBackEn),
     .writeBackALU(writeBackALU),
     .writeBackAplusB(writeBackAplusB),		      
     .writeBackPCplus4(writeBackPCplus4),
     .writeBackCSR(writeBackCSR),		      		      
     .inRegId1(regId1),
     .inRegId2(regId2),
     .aluInSel1(aluInSel1), 
     .aluInSel2(aluInSel2),
     .func(func),
     .funcQual(funcQual),
     .funcM(funcM),		      
     .needWaitALU(needWaitALU),
     .isALU(isALU),		      
     .isLoad(isLoad),
     .isStore(isStore),
     .isJump(isJump),
     .isBranch(isBranch),
     .imm(imm),
     .error(decoderError)     		     
   );

   /***************************************************************************/
   // Maybe not necessary, but I'd rather latch this one,
   // if this one glitches, then it will break everything...
   reg error_latched;
   assign error = error_latched;

   /***************************************************************************/
   // The register file. At each cycle, it can read two
   // registers (available at next cycle) and write one.
   
   wire writeBack; // asserted if register write back is done.
   reg  [31:0] writeBackData;
   wire [31:0] regOut1;
   wire [31:0] regOut2;   
   NrvRegisterFile regs(
    .clk(clk),
    .in(writeBackData),
    .inEn(writeBack),
    .inRegId(writeBackRegId),		       
    .outRegId1(regId1),
    .outRegId2(regId2),
    .out1(regOut1),
    .out2(regOut2) 
   );

   /***************************************************************************/
   // The ALU, partly combinatorial, partly state (for shifts).
   wire [31:0] aluOut;
   wire [31:0] aluAplusB;   
   wire        aluBusy;
   wire        alu_wenable;
   wire [31:0] aluIn1 = aluInSel1 ? {PC, 2'b00} : regOut1;
   wire [31:0] aluIn2 = aluInSel2 ? imm : regOut2;

   // Select the ALU for RV32M (large ALU) or plain RV32I (small ALU)
   generate
      if(RV32M) begin
         NrvLargeALU alu(
            .clk(clk),	      
            .in1(aluIn1),
            .in2(aluIn2),
            .func(func),
            .funcQual(funcQual),
            .funcM(funcM),	 
            .out(aluOut),
	    .AplusB(aluAplusB),
            .wr(alu_wenable), 
            .busy(aluBusy)	      
         );
      end else begin 
         NrvSmallALU #(
`ifdef NRV_TWOSTAGE_SHIFTER	      
          .TWOSTAGE_SHIFTER(1)
`else
          .TWOSTAGE_SHIFTER(0)	      
`endif
         ) alu(
            .clk(clk),	      
            .in1(aluIn1),
            .in2(aluIn2),
            .func(func),
            .funcQual(funcQual),
            .out(aluOut),
	    .AplusB(aluAplusB),	    
            .wr(alu_wenable), 
            .busy(aluBusy)	      
         );
      end
   endgenerate
   
   /***************************************************************************/
   // Memory only does 32-bit aligned accesses. Internally we have two small
   // circuits (one for LOAD and one for STORE) that shift and adapt data
   // according to data type (byte, halfword, word) and 
   // memory alignment (addr[1:0]).
   // In addition, it does sign-expansion (when loading a signed byte 
   // to a word for instance).
   
   // LOAD: a small combinatorial circuit that realigns 
   // and sign-expands mem_rdata based 
   // on width (func[1:0]), signed/unsigned flag (func[2])
   // and the two LSBs of the address. 
   wire [31:0] LOAD_data_aligned_for_CPU;
   NrvLoadFromMemory load_from_mem(
       .mem_rdata(mem_rdata),           // Raw data read from mem
       .addr_LSBs(mem_addr[1:0]),       // The two LSBs of the address
       .width(func[1:0]),               // Data width: 00:byte 01:hword 10:word
       .is_unsigned(func[2]),           // signed/unsigned flag
       .data(LOAD_data_aligned_for_CPU) // Data ready to be sent to register
   );

   // STORE: a small combinatorial circuit that realigns
   // data to be written based on width and the two LSBs
   // of the address.
   // When a STORE instruction is executed, the data to be stored to
   // mem is available from the second register (regOut2) and the
   // address where to store it is the output of the ALU (aluOut).
   wire        mem_wenable;
   wire [31:0] STORE_data_aligned_for_MEM;
   NrvStoreToMemory store_to_mem(
       .data(regOut2),                         // Data to be sent, out of register
       .addr_LSBs(aluAplusB[1:0]),             // The two LSBs of the address
       .width(func[1:0]),                      // Data width: 00:byte 01:hword 10:word
       .mem_wdata(STORE_data_aligned_for_MEM), // Shifted data to be sent to memory
       .mem_wmask(mem_wmask),                  // Write mask for the 4 bytes
       .wr_enable(mem_wenable)                 // Write enable ('anded' with write mask)
   );
   
   /*************************************************************************/
   // Control and status registers
   
`ifdef NRV_CSR
   wire [31:0] CSR_rdata;
   wire        instr_retired;
   NrvControlStatusRegisterFile CSR(
      .clk(clk),                         // for counting cycles
      .instr_cnt(instr_retired),         // for counting retired instructions
      .reset(reset),                     // reset all CSRs to default value
      .CSRid(instr[31:20]),              // CSR Id, extracted from instr
      .rdata(CSR_rdata)                  // Read CSR value
      // TODO: test for errors (.error)
   );
`endif   
   // Note: writing to CSRs not implemented yet

 
   /*************************************************************************/
   // The value written back to the register file.
   
   always @(*) begin
      (* parallel_case, full_case *)
      case(1'b1)
	writeBackALU :    writeBackData = aluOut;
	writeBackAplusB:  writeBackData = aluAplusB;	
	writeBackPCplus4: writeBackData = {PCplus4, 2'b00};
	isLoad:           writeBackData = LOAD_data_aligned_for_CPU;
`ifdef NRV_CSR
	writeBackCSR:     writeBackData = CSR_rdata;	
`endif
      endcase
   end

   /*************************************************************************/
   // The predicate for conditional branches.
   
   wire predOut;
   NrvPredicate pred(
    .in1(regOut1),
    .in2(regOut2),
    .func(func),
    .out(predOut)		    
   );

   /*************************************************************************/
   // And, last but not least, the state machine.
   /*************************************************************************/

   // The states, using 1-hot encoding (reduces
   // both LUT count and critical path).
   
   localparam INITIAL              = 9'b000000000;   
   localparam WAIT_INSTR           = 9'b000000001;
   localparam FETCH_INSTR          = 9'b000000010;
   localparam FETCH_REGS           = 9'b000000100;
   localparam EXECUTE              = 9'b000001000;
   localparam LOAD                 = 9'b000010000;
   localparam WAIT_ALU_OR_DATA     = 9'b000100000;
   localparam STORE                = 9'b001000000;
   localparam WAIT_IO_STORE        = 9'b010000000;   
   localparam ERROR                = 9'b100000000;

   
   localparam WAIT_INSTR_bit           = 0;
   localparam FETCH_INSTR_bit          = 1;
   localparam FETCH_REGS_bit           = 2;
   localparam EXECUTE_bit              = 3;
   localparam LOAD_bit                 = 4;   
   localparam WAIT_ALU_OR_DATA_bit     = 5;
   localparam STORE_bit                = 6;
   localparam WAIT_IO_STORE_bit        = 7;   
   localparam ERROR_bit                = 8;
   
   reg [9:0] state = INITIAL;
   
   // the internal signals that are determined combinatorially from
   // state and other signals.
   
   // The internal signal that enables register write-back
   assign writeBack = (state[EXECUTE_bit] && writeBackEn) || 
                       state[WAIT_ALU_OR_DATA_bit];

   // The memory-read signal. It is only needed for IO, hence it is only enabled
   // right before the LOAD state. To allow execution from IO-mapped devices, it
   // will be necessary to also enable it before instruction fetch.
   assign mem_rstrb = state[LOAD_bit];

   // See also how load_from_mem and store_to_mem are wired.
   assign mem_wenable = state[STORE_bit];

   // alu_wenable starts computation in the ALU (for functions that
   // require several cycles).
   assign alu_wenable = state[EXECUTE_bit];

   // instr_retired is asserted during one cycle for each
   // retired instructions. It is used to update the instruction
   // counter 'instret' in the control and status registers
`ifdef NRV_CSR   
   assign instr_retired = state[FETCH_REGS_bit];
`endif

   // when asserted, next PC is updated from ALU (instead of PC+4)
   wire jump_or_take_branch = isJump || (isBranch && predOut);

   // And now the state machine
   
   always @(posedge clk) begin
      if(!reset) begin	
	 state <= INITIAL;
	 addressReg <= 0;
	 PC <= 0;
      end else

      case(1'b1)

        // *********************************************************************
        // Initial state
	(state == INITIAL):     state <= WAIT_INSTR;
	
        // *********************************************************************	
	// Additional wait state for instruction fetch. 
	// Required by jumps and taken branch.	
	state[WAIT_INSTR_bit]:  state <= FETCH_INSTR; 

        // *********************************************************************
        // Fetch instr and prepare instr lookahead
	//   (instr lookahead is fetched during FETCH_REGS and ready in EXECUTE)	   
	state[FETCH_INSTR_bit]: begin
	   instr <= mem_rdata;
	   addressReg <= {PCplus4, 2'b00};
	   state <= FETCH_REGS;
	end

        // *********************************************************************
        // 1) Fetch registers (instr is ready, as well as register ids)
	// 2) Prefetch next instr, at PC+4 (addressReg is set by all transitions that land here)
	// 3) Latch decoder error flag
	state[FETCH_REGS_bit]: begin
	   state <= EXECUTE;
	   error_latched <= decoderError;
	end
	
        // *********************************************************************	
	// Does 1-cycle ALU ops, or handles jump/branch, or transitions to waitALU, load, store
	//    If linear execution flow, update instr with lookahead and prepare next lookahead	
	state[EXECUTE_bit]: begin
	   nextInstr <= mem_rdata;  // Looked-ahead instr.
	   addressReg <= aluAplusB; // Needed for LOAD,STORE,jump,branch
	   PC <= PCplus4;
	   
	   (* parallel_case, full_case *)	   
	   case (1'b1)
	     error_latched: state <= ERROR;
	     isLoad:        state <= LOAD;
	     isStore:       begin
		state <= STORE;
		wdataReg <= STORE_data_aligned_for_MEM;
	     end
	     needWaitALU:   state <= WAIT_ALU_OR_DATA;	     
	     jump_or_take_branch: begin
		PC <= aluAplusB[31:2];
		state <= WAIT_INSTR;
	     end
	     default: begin // Linear execution flow, use lookahead, prepare next lookahead
		instr <= mem_rdata;  // Use looked-ahead instr.
		addressReg <= {PC + 2'b10, 2'b00}; // Look-ahead: PC+8 (PC not updated yet)
		state <= FETCH_REGS; // Cool, linear exec flow takes 2 CPIs !
	     end
	   endcase
	end 

        // *********************************************************************
        // wait-state for data fetch (LOAD): 
	//    data address (aluOut) was set by EXECUTE, data ready at next cycle (WAIT_ALU_OR_DATA)
	state[LOAD_bit]: state <= WAIT_ALU_OR_DATA;

        // *********************************************************************
        // Data is written to memory by 'NrvStoreToMemory store_to_mem' (see beginning of file)
	//    Next state: linear execution flow-> update instr with lookahead and prepare next lookahead
	state[STORE_bit]: begin
	   instr <= nextInstr;
	   addressReg <= {PCplus4, 2'b00};
	   // If storing to IO device or mapped SPI flash, use wait state.
	   // (needed because mem_wbusy will be available at next cycle).
	   state <= (aluAplusB[22] | aluAplusB[23]) ? WAIT_IO_STORE : FETCH_REGS;
	end

	// *********************************************************************
	// wait-state for IO store 
	state[WAIT_IO_STORE_bit]: begin
	   `verbose($display("        mem_wbusy:%b",mem_wbusy));	   
	   if(!mem_wbusy) 
	     state <= FETCH_REGS;
	end

	
        // *********************************************************************
        // Used by LOAD and by multi-cycle ALU instr (shifts and RV32M ops), writeback from ALU or memory
	//    also waits from data from IO (listens to mem_rbusy)
	//    Next state: linear execution flow-> update instr with lookahead and prepare next lookahead
	state[WAIT_ALU_OR_DATA_bit]: begin
	   `verbose($display("        mem_rbusy:%b",mem_rbusy));
	   if(!aluBusy && !mem_rbusy) begin
	      instr <= nextInstr;
	      addressReg <= {PCplus4, 2'b00};
	      state <= FETCH_REGS;
	   end
	end

	default: state <= ERROR;
	
      endcase
  end   

/*********************************************************************/
// Debugging, test-bench

`define show_state(state)   `verbose($display("    %s",state))
`define show_opcode(opcode) `verbose($display("%x: %s",{PC,2'b00},opcode))
   
`ifdef BENCH
   always @(posedge clk) begin
      case(1'b1)
	(state == 0): begin end	      // `show_state("initial");
	state[WAIT_INSTR_bit]:       `show_state("wait_instr");
	state[FETCH_INSTR_bit]:      `show_state("fetch_instr");
	state[FETCH_REGS_bit]:       `show_state("fetch_regs");
	state[EXECUTE_bit]:          `show_state("execute");
	state[LOAD_bit]:             begin `show_state("load");	`bench($display("        addr: %b",mem_addr)); end
	state[STORE_bit]:            `show_state("store");
	state[WAIT_ALU_OR_DATA_bit]: `show_state("wait_alu_or_data");
	state[WAIT_IO_STORE_bit]:    `show_state("wait_IO_store");	
	state[ERROR_bit]:   	     `bench($display("ERROR"));	   	   	   
	default:  	             `bench($display("UNKNOWN STATE: %b",state));	   	   	   
      endcase
   
      if(state[FETCH_REGS_bit]) begin
	 case(instr[6:0])
	   7'b0110111: `show_opcode("LUI");
	   7'b0010111: `show_opcode("AUIPC");
	   7'b1101111: `show_opcode("JAL");
	   7'b1100111: `show_opcode("JALR");
	   7'b1100011: `show_opcode("BRANCH");
	   7'b0010011: `show_opcode("ALU reg imm");
	   7'b0110011: `show_opcode("ALU reg reg");
	   7'b0000011: `show_opcode("LOAD");
	   7'b0100011: `show_opcode("STORE");
	   7'b0001111: `show_opcode("FENCE");
	   7'b1110011: `show_opcode("SYSTEM");
	 endcase 
      end 
   end
`endif
   
endmodule
