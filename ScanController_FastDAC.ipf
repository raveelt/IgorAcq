﻿#pragma TextEncoding = "UTF-8"
#pragma rtGlobals=3		// Use modern global access method and strict wave access.

// Fast DAC (8 DAC channels + 4 ADC channels). Build in-house by Mark (Electronic work shop).
// This is the ScanController extention to the ScanController code. Running measurements with
// the Fast DAC must be "stand alone", no other instruments can read at the same time.
// The Fast DAC extention will open a seperate "Fast DAC window" that holds all the information
// nessesary to run a Fast DAC measurement. Any "normal" measurements should still be set up in 
// the standard ScanController window.
// It is the users job to add the fastdac=1 flag to initWaves() and SaveWaves()
//
// Written by Christian Olsen, 2019-11-xx

function openFastDACconnection(instrID, visa_address, [verbose,numDACCh,numADCCh])
	// instrID is the name of the global variable that will be used for communication
	// visa_address is the VISA address string, i.e. ASRL1::INSTR
	// Most FastDAC communication relies on the info in "fdackeys". Pass numDACCh and
	// numADCCh to fill info into "fdackeys"
	string instrID, visa_address
	variable verbose, numDACCh, numADCCh
	
	if(paramisdefault(verbose))
		verbose=1
	elseif(verbose!=1)
		verbose=0
	endif
	
	variable localRM
	variable status = viOpenDefaultRM(localRM) // open local copy of resource manager
	if(status < 0)
		VISAerrormsg("open FastDAC connection:", localRM, status)
		abort
	endif
	
	string comm = ""
	sprintf comm, "name=FastDAC,instrID=%s,visa_address=%s" instrID, visa_address
	string options = "baudrate=57600,databits=8,stopbits=1,parity=0"
	openVISAinstr(comm, options=options, localRM=localRM, verbose=verbose)
	
	// fill info into "fdackeys"
	if(!paramisdefault(numDACCh) && !paramisdefault(numADCCh))
		sc_fillfdacKeys(instrID,visa_address,numDACCh,numADCCh)
	endif
	
	return localRM
end

function sc_fillfdacKeys(instrID,visa_address,numDACCh,numADCCh)
	string instrID, visa_address
	variable numDACCh, numADCCh
	
	variable numDevices
	svar fdackeys
	if(!svar_exists(fdackeys))
		string/g fdackeys = ""
		numDevices = 0
	else
		numDevices = str2num(stringbykey("numDevices",fdackeys,":",","))
	endif
	
	variable i=0, deviceNum=numDevices+1
	for(i=0;i<4;i+=1)
		if(cmpstr(instrID,stringbykey("name"+num2istr(i+1),fdackeys,":",","))==0)
			deviceNum = i+1
			break
		endif
	endfor
	
	fdackeys = replacenumberbykey("numDevices",fdackeys,deviceNum,":",",")
	fdackeys = replacestringbykey("name"+num2istr(deviceNum),fdackeys,instrID,":",",")
	fdackeys = replacestringbykey("visa"+num2istr(deviceNum),fdackeys,visa_address,":",",")
	fdackeys = replacenumberbykey("numDACCh"+num2istr(deviceNum),fdackeys,numDACCh,":",",")
	fdackeys = replacenumberbykey("numADCCh"+num2istr(deviceNum),fdackeys,numADCCh,":",",")
	fdackeys = sortlist(fdackeys,",")
end

function fdacRecordValues(instrID,rowNum,rampCh,start,fin,numpts,[ramprate,RCcutoff,numAverage,notch])
	// RecordValues for FastDAC's. This function should replace RecordValues in scan functions.
	// j is outer scan index, if it's a 1D scan just set j=0.
	// rampCh is a comma seperated string containing the channels that should be ramped.
	// Data processing:
	// 		- RCcutoff set the lowpass cutoff frequency
	//		- average set the number of points to average
	//		- nocth sets the notch frequencie, as a comma seperated list (width is fixed at 5Hz)
	variable instrID, rowNum
	string rampCh, start, fin
	variable numpts, ramprate, RCcutoff, numAverage
	string notch
	nvar sc_is2d, sc_startx, sc_starty, sc_finx, sc_starty, sc_finy, sc_numptsx, sc_numptsy
	nvar sc_abortsweep, sc_pause, sc_scanstarttime
	wave/t fadcvalstr
	wave fadcattr
	
	if(paramisdefault(ramprate))
		ramprate = 1000
	endif
	
	// compare to earlier call of InitializeWaves
	nvar fastdac_init
	if(fastdac_init != 1)
		print("[ERROR] \"RecordValues\": Trying to record fastDACs, but they weren't initialized by \"InitializeWaves\"")
		abort
	endif
	
	// Everything below has to be changed if we get hardware triggers!
	// Check that dac and adc channels are all on the same device and sort lists
	// of DAC and ADC channels for scan.
	// When (if) we get hardware triggers on the fastdacs, this function call should
	// be replaced by a function that sorts DAC and ADC channels based on which device
	// they belong to.
	
	variable dev_adc=0
	dev_adc = sc_fdacSortChannels(rampCh,start,fin)
	struct fdacChLists scanList
	
	// move DAC channels to starting point
	variable i=0
	for(i=0;i<itemsinlist(scanList.daclist,",");i+=1)
		rampOutputfdac(instrID,str2num(stringfromlist(i,scanList.daclist,",")),str2num(stringfromlist(i,scanList.startVal,",")),ramprate=ramprate)
	endfor
	
	// build command and start ramp
	// for now we only have to send one command to one device.
	string cmd = ""
	// OPERATION, DAC CHANNELS, ADC CHANNELS, INITIAL VOLTAGES, FINAL VOLTAGES, # OF STEPS, DELAY (MICROSECONDS), #READINGS TO AVG
	sprintf cmd, "BUFFERRAMP %s,%s,%s,%s\r", scanList.daclist, scanlist.adclist, scanList.startVal, scanList.finVal, numpts, 1,1 //FIXME
	writeInstr(instrID,cmd)
	
	// read returned values
	variable totalByteReturn = itemsinlist(scanList.adclist,",")*2*numpts,read_chunk=0
	variable chunksize = itemsinlist(scanList.adclist,",")*2*30
	if(totalByteReturn > chunksize)
		read_chunk = chunksize
	else
		read_chunk = totalByteReturn
	endif
	
	// hold incomming data chunks in string and distribute to data waves
	string buffer = ""
	variable bytes_read = 0
	do
		buffer = readInstr(instrID,read_bytes=read_chunk, fdac_flag=1)
		// If failed, abort
		if (cmpstr(buffer, "NaN") == 0)
			abort
		endif
		// add data to rawwaves and datawaves
		sc_distribute_data(buffer,scanList.adclist,read_chunk,rowNum,bytes_read)
		bytes_read += read_chunk
	while(totalByteReturn-bytes_read > read_chunk)
	// do one last read if any data left to read
	variable bytes_left = totalByteReturn-bytes_read
	if(bytes_left > 0) 
		buffer = readInstr(instrID,read_bytes=bytes_left,fdac_flag=1)
		sc_distribute_data(buffer,scanList.adclist,read_chunk,rowNum,bytes_read)
	endif
	
	// read sweeptime
	variable sweeptime = 0
	buffer = readInstr(instrID,read_bytes=10) // FIX read_bytes
	sweeptime = str2num(buffer)
	
	/////////////////////////
	//// Post processing ////
	/////////////////////////
	
	variable samplingFreq=0
	samplingFreq = getfadcSpeed(instrID)
	
	string warn = ""
	variable doLowpass=0,cutoff_frac=0
	if(!paramisdefault(RCcutoff))
		// add lowpass filter
		doLowpass = 1
		cutoff_frac = RCcutoff/samplingFreq
		if(cutoff_frac > 0.5)
			print("[WARNING] \"fdacRecordValues\": RC cutoff frequency must be lower than half the sampling frequency!")
			sprintf warn, "Setting it to %.2f", 0.5*samplingFreq
			print(warn)
			cutoff_frac = 0.5
		endif
	endif
	
	variable doNotch=0,numNotch=0
	string notch_fracList = ""
	if(!paramisdefault(notch))
		// add notch filter(s)
		doNotch = 1
		numNotch = itemsinlist(notch,",")
		for(i=0;i<numNotch;i+=1)
			notch_fracList = addlistitem(num2str(str2num(stringfromlist(i,notch,","))/samplingFreq),notch_fracList,",",itemsinlist(notch_fracList))
		endfor
	endif
	
	variable doAverage=0
	if(!paramisdefault(numAverage))
		// do averaging
		doAverage = 1
	endif
	
	// setup FIR (Finite Impluse Response) filter(s)
	variable FIRcoefs=0
	if(numpts < 101)
		FIRcoefs = numpts
	else
		FIRcoefs = 101
	endif
	
	string coef = "", coefList = ""
	variable j=0,numfilter=0
	// add RC filter
	if(doLowpass == 1)
		coef = "coefs"+num2istr(numfilter)
		make/o/d/n=0 $coef
		filterfir/lo={cutoff_frac,cutoff_frac,FIRcoefs}/coef $coef
		coefList = addlistitem(coef,coefList,",",itemsinlist(coefList))
		numfilter += 1
	endif
	// add notch filter(s)
	if(doNotch == 1)
		for(j=0;j<numNotch;j+=1)
			coef = "coefs"+num2istr(numfilter)
			make/o/d/n=0 $coef
			filterfir/nmf={str2num(stringfromlist(j,notch_fraclist,",")),15.0/samplingFreq,1.0e-8,1}/coef $coef
			coefList = addlistitem(coef,coefList,",",itemsinlist(coefList))
			numfilter += 1
		endfor
	endif
	
	// apply filters
	if(doLowpass == 1 || doNotch == 1)
		sc_applyfilters(coefList,scanList.adclist,doLowpass,doNotch,cutoff_frac,samplingFreq,FIRcoefs,notch_fraclist,rowNum)
	endif
	
	// average datawaves
	variable lastRow = sc_lastrow(rowNum)
	if(doAverage == 1)
		sc_averageDataWaves(numAverage,scanList.adcList,lastRow,rowNum)
	endif
	
	return sweeptime
end

function sc_lastrow(rowNum)
	variable rowNum
	
	nvar sc_is2d, sc_numptsy
	variable check = 0
	if(sc_is2d)
		check = sc_numptsy-1
	else
		check = sc_numptsy
	endif
	
	if(rowNum != check)
		return 0
	elseif(rowNum == check)
		return 1
	else
		return 0
	endif
end

function sc_applyfilters(coefList,adcList,doLowpass,doNotch,cutoff_frac,samplingFreq,FIRcoefs,notch_fraclist,rowNum)
	string coefList, adcList, notch_fraclist
	variable doLowpass, doNotch, cutoff_frac, samplingFreq, FIRcoefs, rowNum
	wave/t fadcvalstr
	nvar sc_is2d
	
	string wave1d = "", wave2d = "", errmes=""
	variable i=0,j=0,err=0
	for(i=0;i<itemsinlist(adcList,",");i+=1)
		wave1d = fadcvalstr[str2num(stringfromlist(i,adcList,","))][3]
		wave datawave = $wave1d
		for(j=0;j<itemsinlist(coefList,",");j+=1)
			wave coefs = $stringfromlist(j,coefList,",")
			if(doLowpass == 1 && j == 0)
				filterfir/lo={cutoff_frac,cutoff_frac,FIRcoefs}/coef=coefs datawave
			elseif(doNotch == 1)
				try
					filterfir/nmf={str2num(stringfromlist(j,notch_fraclist,",")),15.0/samplingFreq,1.0e-8,1}/coef=coefs datawave
					abortonrte
				catch
					err = getrTError(1)
					if(dimsize(coefs,0) > 2.0*dimsize(datawave,0))
						// nothing we can do. Don't apply filter!
						sprintf errmes, "[WARNING] \"sc_applyfilters\": Notch filter at %.1f Hz not applied. Length of datawave is too short!",str2num(stringfromlist(j,notch_fraclist,","))*samplingFreq
						print errmes
					else
						// try increasing the filter width to 30Hz
						try
							make/o/d/n=0 coefs2
							filterfir/nmf={str2num(stringfromlist(j,notch_fraclist,",")),30.0/samplingFreq,1.0e-8,1}/coef coefs2, datawave
							abortonrte
							if(rowNum == 0 && i == 0)
								sprintf errmes, "[WARNING] \"sc_applyfilters\": Notch filter at %.1f Hz applied with a filter width of 30Hz.", str2num(stringfromlist(j,notch_fraclist,","))*samplingFreq
								print errmes
							endif
						catch
							err = getrTError(1)
							// didn't work
							if(rowNum == 0 && i == 0)
								sprintf errmes, "[WARNING] \"sc_applyfilters\": Notch filter at %.1f Hz not applied. Increasing filter width to 30 Hz wasn't enough.", str2num(stringfromlist(j,notch_fraclist,","))*samplingFreq
								print errmes
							endif
						endtry
					endif
				endtry
			endif
		endfor
		if(sc_is2d)
			wave2d = wave1d+"_2d"
			wave datawave2d = $wave2d
			datawave2d[][rowNum] = datawave[p]
		endif
	endfor
end

function sc_distribute_data(buffer,adcList,bytes,rowNum,colNumStart)
	string buffer, adcList
	variable bytes, rowNum, colNumStart
	wave/t fadcvalstr
	nvar sc_is2d
	
	variable i=0, j=0, k=0, numADCCh = itemsinlist(adcList,","), adcIndex=0, dataPoint=0
	string wave1d = "", wave2d = "", s1, s2
	// load data into raw wave
	for(i=0;i<numADCCh;i+=1)
		adcIndex = str2num(stringfromlist(i,adcList,","))
		wave1d = "ADC"+num2istr(str2num(stringfromlist(i,adcList,",")))
		wave rawwave = $wave1d
		k = 0
		for(j=0;j<bytes;j+=numADCCh*2)
		// Just editing this
			s1 = buffer[j + (i*2)]
			s2 = buffer[j + (i*2) + 1]
			// dataPoint = str2num(stringfromlist(i+j*numADCCh,buffer,","))
			datapoint = fdacChar2Num(s1, s2)
			rawwave[colNumStart+k] = dataPoint
			k += 1
		endfor 
		if(sc_is2d)
			wave2d = wave1d+"_2d"
			wave rawwave2d = $wave2d
			rawwave2d[][rowNum] = rawwave[p]
		endif
	endfor
	
	// load calculated data into datawave
	string script="", cmd=""
	for(i=0;i<numADCCh;i+=1)
		adcIndex = str2num(stringfromlist(i,adcList,","))
		wave1d = fadcvalstr[adcIndex][3]
		wave datawave = $wave1d
		script = trimstring(fadcvalstr[adcIndex][4])
		sprintf cmd, "datawave = %s", script
		execute/q/z cmd
		if(v_flag!=0)
			print "[WARNING] \"sc_distribute_data\": Wave calculation falied! Error: "+GetErrMessage(V_Flag,2)
		endif
		if(sc_is2d)
			wave2d = wave1d+"_2d"
			wave datawave2d = $wave2d
			datawave2d[][rowNum] = datawave[p]
		endif
	endfor
end

function sc_averageDataWaves(numAverage,adcList,lastRow,rowNum)
	variable numAverage, lastRow, rowNum
	string adcList
	wave/t fadcvalstr
	nvar sc_is2d, sc_startx, sc_finx, sc_starty, sc_finy
	
	variable i=0,j=0,k=0,newsize=0,adcIndex=0,numADCCh=itemsinlist(adcList,","),h=numAverage-1
	string wave1d="",wave2d="",avg1d="",avg2d="",graph="",avggraph=""
	for(i=0;i<numADCCh;i+=1)
		adcIndex = str2num(stringfromlist(i,adcList,","))
		wave1d = fadcvalstr[adcIndex][3]
		wave datawave = $wave1d
		newsize = floor(dimsize(datawave,0)/numAverage)
		avg1d = "avg_"+wave1d
		// check if waves are plotted on the same graph
		string key="", graphlist = sc_samegraph(wave1d,avg1d)
		if(str2num(stringbykey("result",graphlist,":",",")) > 1)
			// more than one graph have both waves plotted
			// we need to close one. Let's hope we close the correct one!
			graphlist = removebykey("result",graphlist,":",",")
			for(i=0;i<itemsinlist(graphlist,",")-1;i+=1)
				key = "graph"+num2istr(i)
				killwindow/z $stringbykey(key,graphlist,":",",")
				graphlist = removebykey(key,graphlist,":",",")
			endfor
		endif
		if(lastRow)
			duplicate/o datawave, $avg1d
			make/o/n=(newsize) $wave1d = nan
			wave newdatawave = $wave1d
			setscale/i x, sc_startx, sc_finx, newdatawave
			// average datawave into avgdatawave
			for(j=0;j<newsize;j+=1)
				newdatawave[j] = mean($avg1d,j+j*h,j+h+j*h)
			endfor
			if(sc_is2d)
				nvar sc_numptsy
				// flip colors of traces in 1d graph
				graph = stringfromlist(0,sc_findgraphs(wave1d),",")
				modifygraph/w=$graph rgb($wave1d)=(0,0,65535), rgb($avg1d)=(65535,0,0)
				// average 2d data
				avg2d = "tempwave2d"
				wave2d = wave1d+"_2d"
				duplicate/o $wave2d, $avg2d
				make/o/n=(newsize,sc_numptsy) $wave2d = nan
				wave datawave2d = $wave2d
				setscale/i x, sc_startx, sc_finx, datawave2d
				setscale/i y, sc_starty, sc_finy, datawave2d
				for(k=0;k<sc_numptsy;k+=1)
					duplicate/o/rmd=[][k,k] $avg2d, tempwave
					for(j=0;j<newsize;j+=1)
						datawave2d[j][k] = mean(tempwave,j+j*h,j+h+j*h)
					endfor
				endfor
			endif
		else
			make/o/n=(newsize) $avg1d
			setscale/i x, sc_startx, sc_finx, $avg1d
			wave avgdatawave = $avg1d
			// average datawave into avgdatawave
			for(j=0;j<newsize;j+=1)
				avgdatawave[j] = mean(datawave,j+j*h,j+h+j*h)
			endfor
			if(rowNum == 0)
				// plot on top of datawave
				graphlist = sc_findgraphs(wave1d)
				graph = stringfromlist(itemsinlist(graphlist,",")-1,graphlist,",")
				appendtograph/w=$graph/c=(0,0,65535) avgdatawave
			endif
		endif
	endfor
end

function/s sc_samegraph(wave1,wave2)
	string wave1,wave2
	
	string graphs1="",graphs2=""
	graphs1 = sc_findgraphs(wave1)
	graphs2 = sc_findgraphs(wave2)
	
	variable graphLen1 = itemsinlist(graphs1,","), graphLen2 = itemsinlist(graphs2,","), result=0, i=0, j=0
	string testitem="",graphlist="", graphitem=""
	graphlist=addlistItem("result:0",graphlist,",",0)
	if(graphLen1 > 0 && graphLen2 > 0)
		for(i=0;i<graphLen1;i+=1)
			testitem = stringfromlist(i,graphs1,",")
			for(j=0;j<graphLen2;j+=1)
				if(cmpstr(testitem,stringfromlist(j,graphs2,",")) == 0)
					result += 1
					graphlist = replaceStringbykey("result",graphlist,num2istr(result),":",",")
					sprintf graphitem, "graph%d:%s",result-1,testitem
					graphlist = addlistitem(graphitem,graphlist,",",result)
				endif
			endfor
		endfor
	endif 
	
	return graphlist
end

function/s sc_findgraphs(inputwave)
	string inputwave
	string opengraphs = winlist("*",",","WIN:1"), waveslist = "", graphlist = "", graphname = ""
	variable i=0, j=0
	for(i=0;i<itemsinlist(opengraphs,",");i+=1)
		sprintf graphname, "WIN:%s", stringfromlist(i,opengraphs,",")
		waveslist = wavelist("*",",",graphname)
		for(j=0;j<itemsinlist(waveslist,",");j+=1)
			if(cmpstr(inputwave,stringfromlist(j,waveslist,",")) == 0)
				graphlist = addlistItem(stringfromlist(i,opengraphs,","),graphlist,",")
			endif
		endfor
	endfor
	return graphlist
end

function sc_fdacSortChannels(rampCh,start,fin)
	string rampCh, start, fin
	wave fadcattr
	wave/t fadcvalstr
	svar fdacKeys
	struct fdacChLists s
	
	// check that all DAC channels are on the same device
	variable numRampCh = itemsinlist(rampCh,","),i=0,j=0,dev_dac=0,dacCh=0,startCh=0
	variable numDevices = str2num(stringbykey("numDevices",fdacKeys,":",",")),numDACCh=0
	for(i=0;i<numRampCh;i+=1)
		dacCh = str2num(stringfromlist(i,rampCh,","))
		startCh = 0
		for(j=0;j<numDevices;j+=1)
			numDACCh = str2num(stringbykey("numDACCh"+num2istr(j),fdacKeys,":",","))
			if(startCh+numDACCh-1 >= dacCh)
				// this is the device
				if(i > 0 && dev_dac != j)
					print "[ERROR] \"sc_checkfdacDevice\": All DAC channels must be on the same device!"
					abort
				else
					dev_dac = j
					break
				endif
			endif
			startCh += numDACCh
		endfor
	endfor
	
	// check that all adc channels are on the same device
	variable q=0,numReadCh=0,h=0,dev_adc=0,adcCh=0,numADCCh=0
	string  adcList = ""
	for(i=0;i<dimsize(fadcattr,0);i+=1)
		if(fadcattr[i][2] == 48)
			adcCh = str2num(fadcvalstr[i][0])
			startCh = 0
			for(j=0;j<numDevices;j+=1)
				numADCCh = str2num(stringbykey("numADCCh"+num2istr(j),fdacKeys,":",","))
				if(startCh+numADCCh-1 >= adcCh)
					// this is the device
					if(i > 0 && dev_adc != j)
						print "[ERROR] \"sc_checkfdacDevice\": All ADC channels must be on the same device!"
						abort
					elseif(j != dev_dac)
						print "[ERROR] \"sc_checkfdacDevice\": DAC & ADC channels must be on the same device!"
						abort
					else
						dev_adc = j
						adcList = addlistitem(num2istr(adcCh),adcList,",",itemsinlist(adcList,","))
						break
					endif
				endif
				startCh += numADCCh
			endfor
		endif
	endfor
	
	// add result to structure
	s.daclist = rampCh
	s.adclist = adcList
	s.startVal = start
	s.finVal = fin
	
	return dev_adc
end

// structure to hold DAC and ADC channels to be used in fdac scan.
structure fdacChLists
		string dacList
		string adcList
		string startVal
		string finVal
endstructure

function getfadcSpeed(instrID)
	// Returns speed in Hz (but arduino thinks in microseconds)
	variable instrID

	string response="", compare="", cmd=""

	cmd = "READ_CONVERT_TIME"
	response = queryInstr(instrID,cmd+",0\r",read_term="\r\n")  // Get conversion time for channel 0 (should be same for all channels)
	if(numtype(str2num(response)) != 0)
		abort "[ERROR] \"getfadcSpeed\": device is not connected"
	endif
	
	svar fdackeys
	variable numDevices = str2num(stringbykey("numDevices",fdackeys,":",",")), i=0, numADCCh = 0
	string instrAddress = getResourceAddress(instrID), deviceAddress = ""
	for(i=0;i<numDevices;i+=1)
		deviceAddress = stringbykey("visa"+num2istr(i+1),fdackeys,":",",")
		if(cmpstr(deviceAddress,instrAddress) == 0)
			numADCCh = str2num(stringbykey("numADCCh"+num2istr(i+1),fdackeys,":",","))
			break
		endif
	endfor
	for(i=1;i<numADCCh-1;i+=1)
		compare = queryInstr(instrID,cmd+","+num2str(i)+"\r",read_term="\r\n")
		if(numtype(str2num(compare)) != 0)
			abort "[ERROR] \"getfadcSpeed\": device is not connected"
		elseif(str2num(compare) != str2num(response)) // Ensure ADC channels all have same conversion time
			print "[WARNING] \"getfadcSpeed\": ADC channels 0 & "+num2istr(i)+" have different conversion times!"
		endif
	endfor
	
	return 1.0/(str2num(response)*1.0e-6) // return value in Hz
end

function setfadcSpeed(instrID,speed)
	// speed should be a number between 1-4.
	// slowest=1, slow=2, fast=3 and fastest=4
	variable instrID, speed
	string speeds = "1:372,2:2008,3:6060,4:12195"
	
	// check formatting of speed
	if(speed < 0 || speed > 4)
		print "[ERROR] \"setfadcSpeed\": Speed must be integer between 1-4"
		abort
	endif
	
	svar fdackeys
	variable numDevices = str2num(stringbykey("numDevices",fdackeys,":",",")), i=0, numADCCh = 0, numDevice = 0
	string instrAddress = getResourceAddress(instrID), deviceAddress = "", cmd = "", response = ""
	for(i=0;i<numDevices;i+=1)
		deviceAddress = stringbykey("visa"+num2istr(i+1),fdackeys,":",",")
		if(cmpstr(deviceAddress,instrAddress) == 0)
			numADCCh = str2num(stringbykey("numADCCh"+num2istr(i+1),fdackeys,":",","))
			numDevice = i+1
			break
		endif
	endfor
	for(i=0;i<numADCCh;i+=1)
		sprintf cmd, "CONVERT_TIME,%d,%d\r", i, 1.0/(str2num(stringbykey(num2istr(speed),speeds,":",","))*1.0e-6)  // Convert from Hz to microseconds
		response = queryInstr(instrID, cmd, read_term="\r\n")  //Set all channels at same time (generally good practise otherwise can't read from them at the same time)
		if(numtype(str2num(response) != 0))
			abort "[ERROR] \"setfadcSpeed\": Bad response = " + response
		endif
	endfor
	
	// update window
	string adcSpeedMenu = "fadcSetting"+num2istr(numDevice)
	popupMenu $adcSpeedMenu,mode=speed
end

function resetfdacwindow(fdacCh)
	variable fdacCh
	wave/t fdacvalstr, old_fdacvalstr
	
	fdacvalstr[fdacCh][1] = old_fdacvalstr[fdacCh]
end

function updatefdacWindow(fdacCh)
	variable fdacCh
	wave/t fdacvalstr, old_fdacvalstr
	 
	old_fdacvalstr[fdacCh] = fdacvalstr[fdacCh][1]
end

function rampOutputfdac(instrID,channel,output,[ramprate]) // Units: mV, mV/s
	// ramps a channel to the voltage specified by "output".
	// ramp is controlled locally on DAC controller.
	// channel must be the channel set by the GUI.
	variable instrID, channel, output, ramprate
	wave/t fdacvalstr, old_fdacvalstr
	svar fdackeys
	
	if(paramIsDefault(ramprate))
		ramprate = 500
	endif
	
	variable numDevices = str2num(stringbykey("numDevices",fdackeys,":",","))
	variable i=0, devchannel = 0, startCh = 0, numDACCh = 0
	string deviceAddress = "", err = "", instrAddress = getResourceAddress(instrID)
	for(i=0;i<numDevices;i+=1)
		numDACCh =  str2num(stringbykey("numADCCh"+num2istr(i+1),fdackeys,":",","))
		if(startCh+numDACCh-1 >= channel)
			// this is the device, now check that instrID is pointing at the same device
			deviceAddress = stringbykey("visa"+num2istr(i+1),fdackeys,":",",")
			if(cmpstr(deviceAddress,instrAddress) == 0)
				devchannel = startCh+numDACCh-channel
				break
			else
				sprintf err, "[ERROR] \"rampOutputfdac\": channel %d is not present on devic with address %s", channel, instrAddress
				print(err)
				resetfdacwindow(channel)
				abort
			endif
		endif
		startCh += numDACCh
	endfor
	
	// check that output is within hardware limit
	nvar fdac_limit
	if(abs(output) > fdac_limit)
		sprintf err, "[ERROR] \"rampOutputfdac\": Output voltage on channel %d outside hardware limit", channel
		print err
		resetfdacwindow(channel)
		abort
	endif
	
	// check that output is within software limit
	// overwrite output to software limit and warn user
	if(abs(output) > str2num(fdacvalstr[channel][2]))
		output = sign(output)*str2num(fdacvalstr[channel][2])
		string warn
		sprintf warn, "[WARNING] \"rampOutputfdac\": Output voltage must be within limit. Setting channel %d to %.3fmV", channel, output
		print warn
	endif
	
	// read current dac output and compare to window
	string cmd = "", response = ""
	sprintf cmd, "GET_DAC,%d", devchannel
	response = queryInstr(instrID, cmd+"\r", read_term="\n") // response in Volts
	variable currentOutput = str2num(response)
	
	// check response
	if(numtype(currentOutput) == 0)
		currentOutput = currentOutput*1000 // change units to mV
		// good response
		if(abs(currentOutput-str2num(old_fdacvalstr[channel][1]))<0.4)
			// no discrepancy. Min step size is 20000mV/(2^16-1) = 0.305 mV
		else
			sprintf warn, "[WARNING] \"rampOutputfdac\": Actual output of channel %d is different than expected", channel
			print warn
			old_fdacvalstr[channel][1] = num2str(currentOutput)
			updatefdacwindow(channel)
		endif
	else
		sprintf err, "[ERROR] \"rampOutputfdac\": Bad response! %s", response
		print err
		resetfdacwindow(channel)
		abort
	endif
	
	// ramp channel to output
	variable delay = abs(output-currentOutput)/ramprate
	sprintf cmd, "RAMP_SMART,%d,%.4f,%.3f", devchannel, output, ramprate
	if(delay > 2)
		string delaymsg = ""
		sprintf delaymsg, "Waiting for fastdac Ch%d to ramp to %dmV", channel, output
		response = queryInstrProgress(instrID, cmd+"\r", delay, delaymsg, read_term="\r\n")
	else
		response = queryInstr(instrID, cmd+"\r", read_term="\r\n", delay=delay)
	endif
	
	// check respose
	if(cmpstr(response, "RAMP_FINISHED") == 0)
		fdacvalstr[channel][1] = num2str(output)
		updatefdacWindow(channel)
	else
		sprintf err, "[ERROR] \"rampOutputfdac\": Bad response! %s", response
		print err
		resetfdacwindow(channel)
		abort
	endif
end

function getfadcChannel(instrID,channel) // Units: mV
	// channel must be the channel number given by the GUI!
	variable instrID, channel
	wave/t fadcvalstr
	svar fdackeys
	
	variable numDevices = str2num(stringbykey("numDevices",fdackeys,":",","))
	variable i=0, devchannel = 0, startCh = 0, numADCCh = 0
	string visa_address = "", err = "", instr_address = getResourceAddress(instrID)
	for(i=0;i<numDevices;i+=1)
		numADCCh = str2num(stringbykey("numADCCh"+num2istr(i+1),fdackeys,":",","))
		if(startCh+numADCCh-1 >= channel)
			// this is the device, now check that instrID is pointing at the same device
			visa_address = stringbykey("visa"+num2istr(i+1),fdackeys,":",",")
			if(cmpstr(visa_address, instr_address) == 0)
				devchannel = channel-startCh
				break
			else
				sprintf err, "[ERROR] \"getfdacChannel\": channel %d is not present on device on with address %s", channel, instr_address
				print(err)
				abort
			endif
		endif
		startCh =+ numADCCh
	endfor
	
	// query ADC
	string cmd = ""
	sprintf cmd, "GET_ADC,%d", devchannel
	string response
	response = queryInstr(instrID, cmd+"\r", read_term="\r\n")
	
	// check response
	if(numtype(str2num(response)) == 0) 
		// good response, update window
		fadcvalstr[channel][1] = num2str(str2num(response)*1000)
		return str2num(response)*1000
	else
		sprintf err, "[ERROR] \"getfadcChannel\": Bad response = %s", response
		print err
		abort
	endif
end

function initFastDAC()
	// use the key:value list "fdackeys" to figure out the correct number of
	// DAC/ADC channels to use. "fdackeys" is created when calling "openFastDACconnection".
	svar fdackeys
	if(!svar_exists(fdackeys))
		print("[ERROR] \"initFastDAC\": No devices found!")
		abort
	endif
	
	// hardware limit (mV)
	variable/g fdac_limit = 5000
	
	variable i=0, numDevices = str2num(stringbykey("numDevices",fdackeys,":",","))
	variable numDACCh=0, numADCCh=0
	for(i=0;i<numDevices+1;i+=1)
		if(cmpstr(stringbykey("name"+num2istr(i+1),fdackeys,":",","),"")!=0)
			numDACCh += str2num(stringbykey("numDACCh"+num2istr(i+1),fdackeys,":",","))
			numADCCh += str2num(stringbykey("numADCCh"+num2istr(i+1),fdackeys,":",","))
		endif
	endfor
	
	// create waves to hold control info
	fdacCheckForOldInit(numDACCh,numADCCh)
	
	variable/g num_fdacs = 0
	
	// create GUI window
	string cmd = ""
	//variable winsize_l,winsize_r,winsize_t,winsize_b
	getwindow/z ScanControllerFastDAC wsizeRM
	killwindow/z ScanControllerFastDAC
	sprintf cmd, "FastDACWindow(%f,%f,%f,%f)", v_left, v_right, v_top, v_bottom
	execute(cmd)
	fdacSetGUIinteraction(numDevices)
end

function fdacCheckForOldInit(numDACCh,numADCCh)
	variable numDACCh, numADCCh
	
	variable response
	wave/z fdacvalstr
	wave/z old_fdacvalstr
	if(waveexists(fdacvalstr) && waveexists(old_fdacvalstr))
		response = fdacAskUser(numDACCh)
		if(response == 1)
			// Init at old values
			print "[FastDAC] Init to old values"
		elseif(response == -1)
			// Init to default values
			fdacCreateControlWaves(numDACCh,numADCCh)
			print "[FastDAC] Init to default values"
		else
			print "[Warning] \"fdacCheckForOldInit\": Bad user input - Init to default values"
			fdacCreateControlWaves(numDACCh,numADCCh)
		endif
	else
		// Init to default values
		fdacCreateControlWaves(numDACCh,numADCCh)
	endif
end

function fdacAskUser(numDACCh)
	variable numDACCh
	wave/t fdacvalstr
	
	// can only init to old settings if the same
	// number of DAC channels are used
	if(dimsize(fdacvalstr,0) == numDACCh)
		make/o/t/n=(numDACCh) fdacdefaultinit
		duplicate/o/rmd=[][1] fdacvalstr ,fdacvalsinit
		concatenate/o {fdacdefaultinit,fdacvalsinit}, fdacinit
		execute("fdacInitWindow()")
		pauseforuser fdacInitWindow
		nvar fdac_answer
		return fdac_answer
	else
		return -1
	endif
end

window fdacInitWindow() : Panel
	PauseUpdate; Silent 1 // building window
	NewPanel /W=(100,100,400,630) // window size
	ModifyPanel frameStyle=2
	SetDrawLayer UserBack
	SetDrawEnv fsize= 25,fstyle= 1
	DrawText 20, 45,"Choose FastDAC init" // Headline
	SetDrawEnv fsize= 14,fstyle= 1
	DrawText 40,80,"Old init"
	SetDrawEnv fsize= 14,fstyle= 1
	DrawText 170,80,"Default"
	ListBox initlist,pos={10,90},size={280,390},fsize=16,frame=2
	ListBox initlist,fStyle=1,listWave=root:fdacinit,mode= 0
	Button old_fdacinit,pos={40,490},size={70,20},proc=fdacAskUserUpdate,title="OLD INIT"
	Button default_fdacinit,pos={170,490},size={70,20},proc=fdacAskUserUpdate,title="DEFAULT"
endmacro

function fdacAskUserUpdate(action) : ButtonControl
	string action
	variable/g fdac_answer
	
	strswitch(action)
		case "old_fdacinit":
			fdac_answer = 1
			dowindow/k fdacInitWindow
			break
		case "default_fdacinit":
			fdac_answer = -1
			dowindow/k fdacInitWindow
			break
	endswitch
end

window FastDACWindow(v_left,v_right,v_top,v_bottom) : Panel
	variable v_left,v_right,v_top,v_bottom
	PauseUpdate; Silent 1 // pause everything else, while building the window
	NewPanel/w=(0,0,790,570)/n=ScanControllerFastDAC // window size
	if(v_left+v_right+v_top+v_bottom > 0)
		MoveWindow/w=ScanControllerFastDAC v_left,v_top,V_right,v_bottom
	endif
	ModifyPanel/w=ScanControllerFastDAC framestyle=2, fixedsize=1
	SetDrawLayer userback
	SetDrawEnv fsize=25, fstyle=1
	DrawText 160, 45, "DAC"
	SetDrawEnv fsize=25, fstyle=1
	DrawText 546, 45, "ADC"
	DrawLine 385,15,385,385
	DrawLine 10,385,780,385
	SetDrawEnv dash=7
	Drawline 395,295,780,295
	// DAC, 12 channels shown
	SetDrawEnv fsize=14, fstyle=1
	DrawText 15, 70, "Ch"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 50, 70, "Output (mV)"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 140, 70, "Limit (mV)"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 213, 70, "Label"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 285, 70, "Ramprate\r   (mV/s)"
	ListBox fdaclist,pos={10,75},size={360,270},fsize=14,frame=2,widths={35,90,75,70}
	ListBox fdaclist,listwave=root:fdacvalstr,selwave=root:fdacattr,mode=1
	Button fdacramp,pos={80,354},size={65,20},proc=update_fdac,title="Ramp"
	Button fdacrampzero,pos={200,354},size={90,20},proc=update_fdac,title="Ramp all 0"
	// ADC, 8 channels shown
	SetDrawEnv fsize=14, fstyle=1
	DrawText 405, 70, "Ch"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 435, 70, "Input (mV)"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 515, 70, "Record"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 575, 70, "Wave Name"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 665, 70, "Calc Function"
	ListBox fadclist,pos={400,75},size={385,180},fsize=14,frame=2,widths={25,65,45,80,80}
	ListBox fadclist,listwave=root:fadcvalstr,selwave=root:fadcattr,mode=1
	button updatefadc,pos={400,265},size={90,20},proc=update_fadc,title="Update ADC"
	checkbox sc_PrintfadcBox,pos={500,265},proc=sc_CheckBoxClicked,value=sc_Printfadc,side=1,title="\Z14Print filenames "
	checkbox sc_SavefadcBox,pos={620,265},proc=sc_CheckBoxClicked,value=sc_Saverawfadc,side=1,title="\Z14Save raw data "
	popupMenu fadcSetting1,pos={420,300},proc=update_fadcSpeed,mode=1,title="\Z14ADC1 speed",size={100,20},value="Slowest;Slow;Fast;Fastest"
	popupMenu fadcSetting2,pos={620,300},proc=update_fadcSpeed,mode=1,title="\Z14ADC2 speed",size={100,20},value="Slowest;Slow;Fast;Fastest"
	popupMenu fadcSetting3,pos={420,330},proc=update_fadcSpeed,mode=1,title="\Z14ADC3 speed",size={100,20},value="Slowest;Slow;Fast;Fastest"
	popupMenu fadcSetting4,pos={620,330},proc=update_fadcSpeed,mode=1,title="\Z14ADC4 speed",size={100,20},value="Slowest;Slow;Fast;Fastest"
	popupMenu fadcSetting5,pos={420,360},proc=update_fadcSpeed,mode=1,title="\Z14ADC5 speed",size={100,20},value="Slowest;Slow;Fast;Fastest"
	popupMenu fadcSetting6,pos={620,360},proc=update_fadcSpeed,mode=1,title="\Z14ADC6 speed",size={100,20},value="Slowest;Slow;Fast;Fastest"
	
	// identical to ScanController window
	// all function calls are to ScanController functions
	// instrument communication
	SetDrawEnv fsize=14, fstyle=1
	DrawText 15, 415, "Connect Instrument"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 265, 415, "Open GUI"
	SetDrawEnv fsize=14, fstyle=1
	DrawText 515, 415, "Log Status"
	ListBox sc_InstrFdac,pos={10,420},size={770,100},fsize=14,frame=2,listWave=root:sc_Instr,selWave=root:instrBoxAttr,mode=1, editStyle=1

	// buttons
	button connectfdac,pos={10,525},size={140,20},proc=sc_OpenInstrButton,title="Connect Instr"
	button guifdac,pos={160,525},size={140,20},proc=sc_OpenGUIButton,title="Open All GUI"
	button killaboutfdac, pos={310,525},size={160,20},proc=sc_controlwindows,title="Kill Sweep Controls"
	button killgraphsfdac, pos={480,525},size={150,20},proc=sc_killgraphs,title="Close All Graphs"
	button updatebuttonfdac, pos={640,525},size={140,20},proc=sc_updatewindow,title="Update"
	
	// helpful text
	DrawText 10, 565, "Press Update to save changes."
endmacro

	// set update speed for ADCs
function update_fadcSpeed(s) : PopupMenuControl
	struct wmpopupaction &s
	
	string visa_address = ""
	svar fdackeys
	if(s.eventcode == 2)
		// a menu item has been selected
		strswitch(s.ctrlname)
			case "fadcSetting1":
				visa_address = stringbykey("visa1",fdackeys,":",",")
				break
			case "fadcSetting2":
				visa_address = stringbykey("visa2",fdackeys,":",",")
				break
			case "fadcSetting3":
				visa_address = stringbykey("visa3",fdackeys,":",",")
				break
			case "fadcSetting4":
				visa_address = stringbykey("visa4",fdackeys,":",",")
				break
			case "fadcSetting5":
				visa_address = stringbykey("visa5",fdackeys,":",",")
				break
			case "fadcSetting6":
				visa_address = stringbykey("visa6",fdackeys,":",",")
				break
		endswitch
		
		string tempnamestr = "fdac_window_resource"
		try
			variable viRM = openFastDACconnection(tempnamestr, visa_address, verbose=0)
			nvar tempname = $tempnamestr
		
			setfadcSpeed(tempname,s.popnum)
		catch
			// reset error code, so VISA connection can be closed!
			variable err = GetRTError(1)
				
			viClose(tempname)
			viClose(viRM)
			// silent abort
			abortonvalue 1,10
		endtry
			
			// close temp visa connection
			viClose(tempname)
			viClose(viRM)
		return 0
	else
		// do nothing
		return 0
	endif
end

function update_fdac(action) : ButtonControl //FIX
	string action
	svar fdackeys
	wave/t fdacvalstr
	wave/t old_fdacvalstr
	
	// open temporary connection to FastDACs
	// and update values if needed
	variable i=0,j=0,output = 0, numDACCh = 0, startCh = 0, viRM = 0
	string visa_address = "", tempnamestr = "fdac_window_resource"
	variable numDevices = str2num(stringbykey("numDevices",fdackeys,":",","))
	for(i=0;i<numDevices;i+=1)
		numDACCh = str2num(stringbykey("numDACCh"+num2istr(i+1),fdackeys,":",","))
		if(numDACCh > 0)
			visa_address = stringbykey("visa"+num2istr(i+1),fdackeys,":",",")
			viRM = openFastDACconnection(tempnamestr, visa_address, verbose=0)
			nvar tempname = $tempnamestr
			try
				strswitch(action)
					case "ramp":
						for(j=0;j<numDACCh;j+=1)
							output = str2num(fdacvalstr[startCh+j][1])
							if(output != str2num(old_fdacvalstr[startCh+j][1]))
								rampOutputfdac(tempname,j,output,ramprate=500)
							endif
						endfor
						break
					case "rampallzero":
						for(j=0;j<numDACCh;j+=1)
							rampOutputfdac(tempname,j,0,ramprate=500)
						endfor
						break
				endswitch
			catch
				// reset error code, so VISA connection can be closed!
				variable err = GetRTError(1)
				
				viClose(tempname)
				viClose(viRM)
				// silent abort
				abortonvalue 1,10
			endtry
			
			// close temp visa connection
			viClose(tempname)
			viClose(viRM)
		endif
		startCh =+ numDACCh
	endfor
end

function update_fadc(action) : ButtonControl
	string action
	svar fdackeys
	variable i=0, j=0
	
	string visa_address = "", tempnamestr = "fdac_window_resource"
	variable numDevices = str2num(stringbykey("numDevices",fdackeys,":",","))
	variable numADCCh = 0, startCh = 0, viRm = 0
	for(i=0;i<numDevices;i+=1)
		numADCCh = str2num(stringbykey("numADCCh"+num2istr(i+1),fdackeys,":",","))
		if(numADCCh > 0)
			visa_address = stringbykey("visa"+num2istr(i+1),fdackeys,":",",")
			viRm = openFastDACconnection(tempnamestr, visa_address, verbose=0)
			nvar tempname = $tempnamestr
			try
				for(j=0;j<numADCCh;j+=1)
					getfadcChannel(tempname,startCh+j)
				endfor
			catch
				// reset error
				variable err = GetRTError(1)
				
				viClose(tempname)
				viClose(viRM)
				// silent abort
				abortonvalue 1,10
			endtry
			
			// close temp visa connection
			viClose(tempname)
			viClose(viRM)
		endif
		startCh += numADCCh
	endfor
end

function fdacCreateControlWaves(numDACCh,numADCCh)
	variable numDACCh,numADCCh
	
	// create waves for DAC part
	make/o/t/n=(numADCCh) fdacval0 = "0"
	make/o/t/n=(numDACCh) fdacval1 = "0"
	make/o/t/n=(numDACCh) fdacval2 = "10000"
	make/o/t/n=(numDACCh) fdacval3 = "Label"
	make/o/t/n=(numDACCh) fdacval4 = "1000"
	variable i=0
	for(i=0;i<numDACCh;i+=1)
		fdacval0[i] = num2istr(i)
	endfor
	concatenate/o {fdacval0,fdacval1,fdacval2,fdacval3,fdacval4}, fdacvalstr
	make/o/n=(numDACCh) fdacattr0 = 0
	make/o/n=(numDACCh) fdacattr1 = 2
	concatenate/o {fdacattr0,fdacattr1,fdacattr1,fdacattr1,fdacattr1}, fdacattr
	
	//create waves for ADC part
	make/o/t/n=(numADCCh) fadcval0 = "0"
	make/o/t/n=(numADCCh) fadcval1 = "0"
	make/o/t/n=(numADCCh) fadcval2 = ""
	make/o/t/n=(numADCCh) fadcval3 = ""
	make/o/t/n=(numADCCh) fadcval4 = ""
	for(i=0;i<numADCCh;i+=1)
		fadcval0[i] = num2istr(i)
		fadcval3[i] = "wave"+num2istr(i)
		fadcval4[i] = "ADC"+num2istr(i)
	endfor
	concatenate/o {fadcval0,fadcval1,fadcval2,fadcval3,fadcval4}, fadcvalstr
	make/o/n=(numADCCh) fadcattr0 = 0
	make/o/n=(numADCCh) fadcattr1 = 2
	make/o/n=(numADCCh) fadcattr2 = 32
	concatenate/o {fadcattr0,fadcattr0,fadcattr2,fadcattr1,fadcattr1}, fadcattr
	

	variable/g sc_printfadc = 0
	variable/g sc_saverawfadc = 0

	// clean up
	killwaves fdacval0,fdacval1,fdacval2,fdacval3,fdacval4
	killwaves fdacattr0,fdacattr1
	killwaves fadcval0,fadcval1,fadcval2,fadcval3,fadcval4
	killwaves fadcattr0,fadcattr1,fadcattr2
end

function fdacSetGUIinteraction(numDevices)
	variable numDevices
	
	// edit interaction mode popup menus if nessesary
	switch(numDevices)
		case 1:
			popupMenu fadcSetting2, disable=2
			popupMenu fadcSetting3, disable=2
			popupMenu fadcSetting4, disable=2
			popupMenu fadcSetting5, disable=2
			popupMenu fadcSetting6, disable=2
			break
		case 2:
			popupMenu fadcSetting3, disable=2
			popupMenu fadcSetting4, disable=2
			popupMenu fadcSetting4, disable=2
			popupMenu fadcSetting5, disable=2
			popupMenu fadcSetting6, disable=2
			break
		case 3:
			popupMenu fadcSetting4, disable=2
			popupMenu fadcSetting5, disable=2
			popupMenu fadcSetting6, disable=2
			break
		case 4:
			popupMenu fadcSetting5, disable=2
			popupMenu fadcSetting6, disable=2
			break
		case 5:
			popupMenu fadcSetting6, disable=2
			break
		default:
			if(numDevices > 6)
				print("[WARNINIG] \"FastDAC GUI\": More than 6 devices are hooked up.")
				print("Call \"setfadcSpeed\" to set the speeds of the devices not displayed in the GUI.")
			endif
	endswitch
end

// Given two strings of length 1
//  - c1 (higher order) and
//  - c2 lower order
// Calculate effective FastDac value
// @optparams minVal, maxVal (units mV)

function fdacChar2Num(c1, c2, [minVal, maxVal])
	string c1, c2
	variable minVal, maxVal
	// Set default values for minVal & maxVal
	if(paramisdefault(minVal))
		minVal = -10000
	endif
	
	if(paramisdefault(maxVal))
		maxVal = 10000
	endif
	// Check params for violation
	if(strlen(c1) != 1 || strlen(c2) != 1)
		print "[ERROR] strlen violation -- strings passed to fastDacChar2Num must be length 1"
		return 0
	endif
	variable b1, b2
	// Calculate byte values
	b1 = char2num(c1[0])
	b2 = char2num(c2[0])
	// Convert to unsigned
	if (b1 < 0)
		b1 += 256
	elseif (b2 < 0)
		b2 += 256
	endif
	// Return calculated FastDac value
	return ((b1*2^8 + b2)*(maxVal-minVal)/(2^16 - 1))-minVal
	
end