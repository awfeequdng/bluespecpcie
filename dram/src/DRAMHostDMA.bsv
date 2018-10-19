/**
Note:
Commands operate on 4 KB pages
Host offset/cpy bytes limited to 32 bits
**/


import Clocks::*;
import FIFO::*;
import BRAMFIFO::*;
import FIFOF::*;
import Vector::*;

import MergeN::*;

import DRAMController::*;
import DRAMControllerTypes::*;
import DRAMBurstController::*;

import PcieCtrl::*;

interface DRAMHostDMAIfc;
	method ActionValue#(IOWrite) dataReceive;
	method ActionValue#(IOReadReq) dataReq;
	method Action dataSend(IOReadReq ioreq, Bit#(32) data );

	interface DRAMBurstControllerIfc dram;
endinterface

function Bit#(128) reverseEndian(Bit#(128) data);
	Bit#(32) d1 = data[31:0];
	Bit#(32) d2 = data[(32*2)-1:(32*1)];
	Bit#(32) d3 = data[(32*3)-1:(32*2)];
	Bit#(32) d4 = data[127:(32*3)];

	return {d1,d2,d3,d4};
endfunction

module mkDRAMHostDMA#(PcieUserIfc pcie, DRAMBurstControllerIfc dram) (DRAMHostDMAIfc);
	Clock pcieclk = pcie.user_clk;
	Reset pcierst = pcie.user_rst;

	Clock dramclk = dram.user_clk;
	Reset dramrst = dram.user_rst;

	Clock curclk <- exposeCurrentClock;
	Reset currst <- exposeCurrentReset;
	
    SyncFIFOIfc#(IOWrite) pcieOutQ <- mkSyncFIFO(32, pcieclk, pcierst, curclk);
    SyncFIFOIfc#(IOReadReq) pcieReadReqQ <- mkSyncFIFO(32, pcieclk, pcierst, curclk);
    SyncFIFOIfc#(Tuple2#(IOReadReq, Bit#(32))) pcieResponseQ <- mkSyncFIFO(32, curclk, currst, pcieclk);

	Reg#(Bit#(32)) hostMemOff<- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	
	Reg#(Bit#(32)) memReadLeft <- mkReg(0, clocked_by pcieclk, reset_by pcierst); // host->fpga
	Reg#(Bit#(32)) memWriteLeft <- mkReg(0, clocked_by pcieclk, reset_by pcierst); // fpga->host

	
	/**************************************
	** DMA Host -> DRAM Start
	**************************************/
	// 32 in flight good?
    SyncFIFOIfc#(Tuple2#(Bit#(64), Bit#(32))) dmaReadWordCntQ <- mkSyncFIFO(32, pcieclk, pcierst, dramclk);
	
	Integer dmaReadTagCount  = 32;
	FIFO#(Bit#(8)) dmaReadFreeTagQ <- mkSizedFIFO(dmaReadTagCount, clocked_by pcieclk, reset_by pcierst);
	Vector#(32, Reg#(Bit#(8))) vDmaReadTagWordsLeft <- replicateM(mkReg(0, clocked_by pcieclk, reset_by pcierst));
	Reg#(Bit#(8)) dmaReadTagInit <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bool) dmaReadTagInitDone <- mkReg(False, clocked_by pcieclk, reset_by pcierst);
	rule initDmaTagR(dmaReadTagInit < fromInteger(dmaReadTagCount));
		dmaReadTagInit <= dmaReadTagInit + 1;
		dmaReadFreeTagQ.enq(dmaReadTagInit);
		if ( dmaReadTagInit + 1 >= fromInteger(dmaReadTagCount) ) begin
			dmaReadTagInitDone <= True;
		end
	endrule

	rule sendDMARead ( dmaReadTagInitDone && memReadLeft > 0 && memWriteLeft == 0);
		dmaReadFreeTagQ.deq;
		Bit#(8) freeTag = dmaReadFreeTagQ.first;

		if ( memReadLeft >= 128 ) begin
			Bit#(8) words = (128>>4);
			pcie.dmaReadReq(hostMemOff, zeroExtend(words), freeTag);
			
			memReadLeft <= memReadLeft - 128;
			hostMemOff <= hostMemOff + 128;
			vDmaReadTagWordsLeft[freeTag] <= words;
		end else begin
			// +8 to take ceiling, but should not happen because 4KB units
			Bit#(8) words = truncate((memReadLeft+8)>>4);
			pcie.dmaReadReq(hostMemOff, zeroExtend(words), freeTag);

			memReadLeft <= 0;
			vDmaReadTagWordsLeft[freeTag] <= words;
		end
	endrule
    SyncFIFOIfc#(Bit#(128)) dmaReadWordsQ <- mkSyncFIFO(32, pcieclk, pcierst, dramclk);
	Reg#(Maybe#(Bit#(128))) dmaFirstWord <- mkReg(tagged Invalid, clocked_by pcieclk, reset_by pcierst);
	rule getDMARead ( dmaReadTagInitDone );
		let d_ <- pcie.dmaReadWord;


		let dw = reverseEndian(d_.word);
		let dt = d_.tag;


		if ( !isValid(dmaFirstWord) ) begin
			dmaFirstWord <= tagged Valid dw;
		end
		let word = dw;
		let tag = dt;
		if ( vDmaReadTagWordsLeft[tag] == 1 ) begin
			vDmaReadTagWordsLeft[tag] <= 0;
			dmaReadFreeTagQ.enq(tag);
			dmaReadWordsQ.enq(word);
		end else if ( vDmaReadTagWordsLeft[tag] == 0 ) begin
		end else begin
			vDmaReadTagWordsLeft[tag] <= vDmaReadTagWordsLeft[tag] - 1;
			dmaReadWordsQ.enq(word);
		end
	endrule
	// units are DMA WORDS! not DRAM WORDS!
	Reg#(Bit#(32)) dramWriteBurstLeft <- mkReg(0, clocked_by dramclk, reset_by dramrst);
	rule dramStartBurst ( dramWriteBurstLeft == 0 );
		dmaReadWordCntQ.deq;
		let cnt = dmaReadWordCntQ.first;
		let words = tpl_2(cnt);
		let off = tpl_1(cnt);
		Bit#(32) dramwords = (words>>2);// 128bit dma words, 512bit dram words
		dram.writeReq(off, dramwords); 
		dramWriteBurstLeft <= words;
	endrule
	Reg#(Bit#(512)) dramWriteBuffer <- mkReg(0, clocked_by dramclk, reset_by dramrst);
	Reg#(Bit#(2)) dramWriteBufferOffset <- mkReg(0, clocked_by dramclk, reset_by dramrst);
	
	SyncFIFOIfc#(Bool) dramWriteBurstDoneQ <- mkSyncFIFO(32, dramclk, dramrst, pcieclk);
	rule relayDRAMWriteBurst(dramWriteBurstLeft > 0);
		let d = dmaReadWordsQ.first;
		dmaReadWordsQ.deq;
		//let d = {32'h11223344, 32'hcccccccc, 32'h99887766, 32'hdeadbeef};
		dramWriteBurstLeft <= dramWriteBurstLeft - 1;
		if ( dramWriteBurstLeft == 1 ) begin
			dramWriteBurstDoneQ.enq(True);
		end

		if ( dramWriteBufferOffset == 3 || dramWriteBurstLeft == 1 ) begin
			dram.write({truncate(dramWriteBuffer),d});
			dramWriteBufferOffset <= 0;
		end else begin
			dramWriteBuffer <= {truncate(dramWriteBuffer),d};
			dramWriteBufferOffset <= dramWriteBufferOffset + 1;
		end
	endrule
	/**************************************
	** DMA Host -> DRAM End
	**************************************/




	/*****************************************************
	** DMA DRAM -> Host Start
	**************************************/

	Integer dmaWriteTagCount  = 32;
	FIFO#(Bit#(8)) dmaWriteFreeTagQ <- mkSizedFIFO(dmaWriteTagCount, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bit#(8)) dmaWriteTagInit <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bool) dmaWriteTagInitDone <- mkReg(False, clocked_by pcieclk, reset_by pcierst);
	rule initDmaTagW(dmaWriteTagInit < fromInteger(dmaWriteTagCount) && dmaWriteTagInitDone == False);
		dmaWriteTagInit <= dmaWriteTagInit + 1;
		dmaWriteFreeTagQ.enq(fromInteger(dmaReadTagCount)+dmaWriteTagInit);
		if ( dmaWriteTagInit >= fromInteger(dmaWriteTagCount) - 1 ) begin
			dmaWriteTagInitDone <= True;
		end
	endrule


    SyncFIFOIfc#(Tuple2#(Bit#(64), Bit#(32))) dramReadWordCntQ <- mkSyncFIFO(32, pcieclk, pcierst, dramclk);
	SyncFIFOIfc#(Bit#(512)) dramReadWordQ <- mkSyncFIFO(16, dramclk, dramrst, pcieclk);
	Reg#(Bit#(32)) dramBurstReadLeft <- mkReg(0, clocked_by dramclk, reset_by dramrst);

	rule startDRAMRead ( dramBurstReadLeft == 0 );
		dramReadWordCntQ.deq;
		let r = dramReadWordCntQ.first;
		let off = tpl_1(r);
		let words = tpl_2(r);
		dram.readReq(off, words);
		dramBurstReadLeft <= words;
	endrule
	rule relayDRAMWord ( dramBurstReadLeft > 0 );
		let d <- dram.read;
		dramBurstReadLeft <= dramBurstReadLeft - 1;
		dramReadWordQ.enq(d);
	endrule
	
	
	Reg#(Bit#(8)) dmaWriteCurTag <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	FIFO#(Tuple2#(Bit#(32), Bit#(8))) pcieWriteReqQ <- mkFIFO(clocked_by pcieclk, reset_by pcierst);
	
	FIFO#(Bool) dramReadBurstDoneQ <- mkFIFO(clocked_by pcieclk, reset_by pcierst);
	rule genPcieDmaWrite(memWriteLeft > 0 && memReadLeft == 0 );

		if ( memWriteLeft > 128 ) begin
			memWriteLeft <= memWriteLeft - 128;

			Bit#(8) words = (128>>4);
			hostMemOff <= hostMemOff + 128;
			//pcie.dmaWriteReq(hostMemOff, zeroExtend(words), writeTag);
			pcieWriteReqQ.enq(tuple2(hostMemOff, words));
			dramReadBurstDoneQ.enq(False);
		end else begin
			memWriteLeft <= 0;
			
			// +8 to take ceiling, but should not happen because 4KB units
			Bit#(8) words = truncate(memWriteLeft>>4);
			if ( memWriteLeft[3:0] > 0 ) words = words + 1;

			//pcie.dmaWriteReq(hostMemOff, zeroExtend(words), writeTag);
			pcieWriteReqQ.enq(tuple2(hostMemOff, words));

			dramReadBurstDoneQ.enq(True);
		end
	endrule

	FIFO#(Bit#(512)) dramReadWordQ2 <- mkSizedBRAMFIFO(128, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bit#(16)) dramReadWordCntUp <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bit#(16)) dramReadWordCntDn <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	rule relayDRAMRead;
		dramReadWordQ.deq;
		let d = dramReadWordQ.first;
		dramReadWordQ2.enq(d);
		dramReadWordCntUp <= dramReadWordCntUp + 1;
	endrule


	Reg#(Bit#(8)) dmaCurWriteLeft <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bool) dmaCurWriteLast <- mkReg(False, clocked_by pcieclk, reset_by pcierst); 
	// send DMA req only when there are enough words already read from DRAM
	rule sendPcieDmaWrite(dmaCurWriteLeft == 0 && dramReadWordCntUp-dramReadWordCntDn >= zeroExtend(tpl_2(pcieWriteReqQ.first)>>2));
		let d = pcieWriteReqQ.first;
		pcieWriteReqQ.deq;
		
		Bit#(8) writeTag = dmaWriteFreeTagQ.first;
		dmaWriteFreeTagQ.deq;
		dmaWriteCurTag <= writeTag;

		let off = tpl_1(d);
		let words = tpl_2(d);

		pcie.dmaWriteReq(off, zeroExtend(words), writeTag);
		dmaCurWriteLeft <= words;

		dramReadBurstDoneQ.deq;
		dmaCurWriteLast <= dramReadBurstDoneQ.first;
	endrule
	Reg#(Bit#(512)) dmaWriteDRAMWordBuffer <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bit#(2)) dmaWriteDRAMWordBufferOffset <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	FIFO#(Bool) pcieDmaWriteDoneQ <- mkSizedFIFO(16, clocked_by pcieclk, reset_by pcierst);
	rule splitDRAMWord(dmaCurWriteLeft > 0 && dmaWriteTagInitDone == True);
		dmaCurWriteLeft <= dmaCurWriteLeft - 1;
		dmaWriteDRAMWordBufferOffset <= dmaWriteDRAMWordBufferOffset + 1;

		if ( dmaCurWriteLeft == 1 ) begin
			dmaWriteFreeTagQ.enq(dmaWriteCurTag);

			if (dmaCurWriteLast ) begin
				pcieDmaWriteDoneQ.enq(True);
			end
		end


		if (dmaWriteDRAMWordBufferOffset == 0 ) begin
			dramReadWordQ2.deq;
			let d = dramReadWordQ2.first;
			dramReadWordCntDn <= dramReadWordCntDn + 1;

			pcie.dmaWriteData(reverseEndian(d[511:(512-128)]), dmaWriteCurTag);
			dmaWriteDRAMWordBuffer <= (d<<128);
		end else begin
			pcie.dmaWriteData(reverseEndian(dmaWriteDRAMWordBuffer[511:(512-128)]), dmaWriteCurTag);
			dmaWriteDRAMWordBuffer <= (dmaWriteDRAMWordBuffer<<128);
		end
	endrule
    
	
	/**************************************
	** DMA DRAM -> Host End
	****************************************************/

	Reg#(Bit#(32)) dramWriteBurstDoneCount <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bit#(32)) dramReadBurstDoneCount <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	rule accDRAMBurstDone;
		dramWriteBurstDoneQ.deq;
		dramWriteBurstDoneCount <= dramWriteBurstDoneCount + 1;
	endrule
	rule accDRAMBurstRDone;
		pcieDmaWriteDoneQ.deq;
		dramReadBurstDoneCount <= dramReadBurstDoneCount + 1;
	endrule

	FIFO#(Tuple4#(Bool, Bit#(32), Bit#(32), Bit#(32))) dmaCmdQ <- mkFIFO(clocked_by pcieclk, reset_by pcierst);
	rule procCmd( memReadLeft == 0 && memWriteLeft == 0 );
		let d = dmaCmdQ.first;
		dmaCmdQ.deq;
		let write = tpl_1(d);
		let hostpage = tpl_2(d);
		let fpgapage = tpl_3(d);
		let pages = tpl_4(d);
		hostMemOff <= (hostpage<<12);
		let fpgamemoff = (zeroExtend(fpgapage)<<12);
		if ( write ) begin // fpga->host
			memWriteLeft <= (pages<<12);
			dramReadWordCntQ.enq(tuple2(fpgamemoff, (pages<<6))); // Units are DRAM words (64B)
		end else begin // host->fpga
			memReadLeft <= (pages<<12);
			dmaReadWordCntQ.enq(tuple2(fpgamemoff, (pages<<8))); // Units are DMA words (16B)
		end
	endrule
	Reg#(Bit#(32)) hostMemTemp <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	Reg#(Bit#(32)) fpgaMemTemp <- mkReg(0, clocked_by pcieclk, reset_by pcierst);
	rule getCmd; // ( memReadLeft == 0 && memWriteLeft == 0 );
		let w <- pcie.dataReceive;
		let a = w.addr;
		let d = w.data;
		let off = (a>>2);

		// Commands operate on 4 KB pages!
		if ( off == 256 ) begin // hostoff
			//hostMemOff <= (d<<12);
			hostMemTemp <= d;
		end else if ( off == 257 ) begin // fpgaoff
			fpgaMemTemp <= d;
		end else if ( off == 258 ) begin // host->fpga
			dmaCmdQ.enq(tuple4(False, hostMemTemp, fpgaMemTemp, d));
			//memReadLeft <= (d<<12);
		end else if ( off == 259 ) begin // fpga->host
			dmaCmdQ.enq(tuple4(True, hostMemTemp, fpgaMemTemp, d));
			//memWriteLeft <= (d<<12);
		end else begin
			if ( pcieOutQ.notFull() ) begin
				pcieOutQ.enq(w);
			end
		end
	endrule

	Merge2Ifc#(Tuple2#(IOReadReq, Bit#(32))) mergeRead <- mkMerge2(clocked_by pcieclk, reset_by pcierst);
	rule readStat;
		let r <- pcie.dataReq;
		let a = r.addr;
		let off = (a>>2);
		if ( off == 256 ) begin
			//pcie.dataSend(r, dramWriteBurstDoneCount);
			mergeRead.enq[0].enq(tuple2(r, dramWriteBurstDoneCount));
		end else if ( off == 257 ) begin
			//pcie.dataSend(r, dramReadBurstDoneCount);
			mergeRead.enq[0].enq(tuple2(r, dramReadBurstDoneCount));
		end else if ( off == 258 ) begin
			if ( isValid(dmaFirstWord) ) begin
				mergeRead.enq[0].enq(tuple2(r, truncate(fromMaybe(?,dmaFirstWord))));
				dmaFirstWord <= tagged Valid (fromMaybe(?,dmaFirstWord)>>32);
			end else begin
				mergeRead.enq[0].enq(tuple2(r, 32'hffffffff));
			end
		end else begin
			pcieReadReqQ.enq(r);
		end
	endrule
	rule relayUserResp;
		pcieResponseQ.deq;
		mergeRead.enq[1].enq(pcieResponseQ.first);
	endrule
	rule sendPcieRead;
		mergeRead.deq;
		let r = mergeRead.first;
		pcie.dataSend(tpl_1(r), tpl_2(r));
	endrule
	
	/***************************************************
	** Chained DRAM interface start
	*********************************/

	Reg#(Bit#(32)) chainReadWordsLeft <- mkReg(0, clocked_by dramclk, reset_by dramrst);
	Reg#(Bit#(32)) chainWriteWordsLeft <- mkReg(0, clocked_by dramclk, reset_by dramrst);
    SyncFIFOIfc#(Tuple3#(Bool, Bit#(64), Bit#(32))) chainIoCmdQ <- mkSyncFIFO(16, curclk, currst, dramclk);
	SyncFIFOIfc#(Bit#(512)) chainWriteQ <- mkSyncFIFO(16, curclk, currst, dramclk);
    SyncFIFOIfc#(Bit#(512)) chainReadQ <- mkSyncFIFO(16, dramclk, dramrst, curclk);
	rule relayChainCmd( chainReadWordsLeft == 0 && chainWriteWordsLeft == 0 );
		let c = chainIoCmdQ.first;
		chainIoCmdQ.deq;

		let write = tpl_1(c);
		let addr = tpl_2(c);
		let words = tpl_3(c);

		if ( write ) begin
			dram.writeReq(addr, words); 
			chainWriteWordsLeft <= words;
		end else begin
			dram.readReq(addr, words); 
			chainReadWordsLeft <= words;
		end
	endrule

	rule relayChainWrite ( chainWriteWordsLeft > 0 ) ;
		chainWriteWordsLeft <= chainWriteWordsLeft - 1;
		chainWriteQ.deq;
		dram.write(chainWriteQ.first);
	endrule
	rule relayChainRead ( chainReadWordsLeft > 0 ) ;
		chainReadWordsLeft <= chainReadWordsLeft - 1;
		let d <- dram.read;
		chainReadQ.enq(d);
	endrule

	/********************************
	** Chained DRAM interface end
	****************************************************/

	/***************************************************
	** Interface start
	*********************************/
	
	method ActionValue#(IOWrite) dataReceive;
		pcieOutQ.deq;
		return pcieOutQ.first;
	endmethod
	method ActionValue#(IOReadReq) dataReq;
		pcieReadReqQ.deq;
		return pcieReadReqQ.first;
	endmethod
	method Action dataSend(IOReadReq ioreq, Bit#(32) data );
		pcieResponseQ.enq(tuple2(ioreq, data));
	endmethod

	interface DRAMBurstControllerIfc dram;
	interface Clock user_clk = dram.user_clk;
	interface Reset user_rst = dram.user_rst;
	method Action writeReq(Bit#(64) addr, Bit#(32) words);
		chainIoCmdQ.enq(tuple3(True, addr, words));
	endmethod
	method Action readReq(Bit#(64) addr, Bit#(32) words);
		chainIoCmdQ.enq(tuple3(False, addr, words));
	endmethod
	method Action write(Bit#(512) word);
		chainWriteQ.enq(word);
	endmethod
	method ActionValue#(Bit#(512)) read;
		chainReadQ.deq;
		return chainReadQ.first;
	endmethod
	endinterface
endmodule
