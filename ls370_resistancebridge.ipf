﻿#pragma TextEncoding = "UTF-8"
#pragma rtGlobals=1		// Use modern global access method

// Driver for controling a Dilution fridge, via a LakeShore 370 controller and an intermidiate server
// running on a RPi.
// Call SetSystem() before anything else. Current supported systems are: BFsmall, IGH
// Communicates with server over http.
// Procedure written by Christian Olsen 2018-03-xx

// Todo:
// GetTempDB()
// GetHeaterPowerDB()
// GetPressureDB()
// QueryDB()
// Add support for BF #2

////////////////////////////
//// Initiate Lakeshore ////
///////////////////////////

function initLS370()
	setLS370system() // Set the correct system!
	createLS370globals() // Create the needed global variables for the GUI
	// Build main control window
	dowindow/k Lakeshore
	execute("lakeshore_window()")
	// Update current values
	updateLS370GUI()
end

///////////////////////
//// Get Functions ////
//////////////////////

function getLS370temp(plate, [max_age]) // Units: K
	// returns the temperature of the selected "plate".
	// avaliable plates on BF systems: mc (mixing chamber), still, magnet, 4K, 50K
	// avaliable plates on IGH systems: mc (mixing chamber), cold plate, still, 1K, sorb
	// max_age determines how old a reading can be (in sec), before I demand a new one
   // from the server
   // max_age=0 always requests a new reading

	string plate
	variable max_age
	svar system, bfchannellookup, ighchannellookup
	variable channel_idx, channel
	string headers, command, url, token = "vMqyDIcB"

	if(paramisdefault(max_age))
		//return GetTempDB(plate) // Maybe it is better to set max_age = 120
		max_age = 120
	endif

	strswitch(system)
		case "bfsmall":
			channel_idx = whichlistitem(plate,bfchannellookup,";")
			if(channel_idx < 0)
				printf "The requested plate (%s) doesn't exsist!", plate
				return 0.0
			else
				channel = str2num(stringfromlist(channel_idx+5,bfchannellookup,";"))
			endif
			break
		case "igh":
			channel_idx = whichlistitem(plate,ighchannellookup,";")
			if(channel_idx < 0)
				printf "The requested plate (%s) doesn't exsist!", plate
				return 0.0
			else
				channel = str2num(stringfromlist(channel_idx+5,ighchannellookup,";"))
			endif
			break
		case "bfbig":
			break
	endswitch
	
	headers = "Content-Type: application/json"
	sprintf command, "get-channel-data/%d?max_age=%d&_at_=%s", channel, max_age, token
	url = generateLS370URL(command)
	return str2num(queryLS370(url,headers,"t","get"))
end

function getLS370heaterpower(heater, [max_age]) // Units: mW
	// returns the power of the selected heater.
	// avaliable heaters on BF systems: still (analog 2), mc
	// avaliable heaters on IGH systems: sorb (analog 1), still (analog 2), mc
	// max_age determines how old a reading can be (in sec), before a new is demanded
	// from the server
   // max_age=0 always requests a new reading

   string heater
   variable max_age
   svar system, bfheaterlookup, ighheaterlookup
   variable heater_idx, channel
   string headers, command, url, token = "vMqyDIcB"

   if(paramisdefault(max_age))
		//return GetHeaterPowerDB(heater)
		max_age = 120
	endif

	strswitch(system)
		case "bfsmall":
			heater_idx = whichlistitem(heater,bfheaterlookup,";")
			if(heater_idx < 0)
				printf "The requested heater (%s) doesn't exsist!", heater
				return -1.0
			else
				channel = str2num(stringfromlist(heater_idx+2,bfheaterlookup,";"))
			endif
			break
		case "igh":
			heater_idx = whichlistitem(heater,ighheaterlookup,";")
			if(heater_idx < 0)
				printf "The requested heater (%s) doesn't exsist!", heater
				return -1.0
			else
				channel = str2num(stringfromlist(heater_idx+3,ighheaterlookup,";"))
			endif
			break
		case "bfbig":
			break
	endswitch

	headers = "Content-Type: application/json"
	if(channel > 0)
		sprintf command, "get-analog-data/%d?max_age=%d&_at_=%s", channel, max_age, token
	else
		sprintf command, "get-heater-data?max_age=%d&_at_=%s", max_age, token
	endif
	url = generateLS370URL(command)
	return str2num(queryLS370(url,headers,"power_mw","get"))
end

function getLS370PIDtemp() // Units: mK
	// returns the setpoint of the PID loop.
	// the setpoint is set regardless of the actual state of the PID loop
	// and one can therefore always read the current setpoint (active or not)
	variable temp
	string headers, payload, url, command, token = "vMqyDIcB"
	nvar temp_set

	headers = "Content-Type: application/json"
	payload = "{\"command\": \"SETP?\"}"
	sprintf command, "command?_at_=%s", token
	url = generateLS370URL(command)
	string test = queryLS370(url,headers,"v","post",payload=payload)
	temp = str2num(test[1,inf])*1000
	temp_set = temp

	return temp
end

function/s getLS370heaterrange() // Units: AU
	// range must be a number between 0 and 8
	variable range
	string command,payload,headers,url,response,token = "vMqyDIcB"
	
	sprintf payload, "{\"command\": \"HTRRNG?\"}", range
	sprintf command, "command?_at_=%s", token
	headers = "Content-Type: application/json"
	url = generateLS370URL(command)
	response = queryLS370(url,headers,"v","post",payload=payload)
	return response[1,inf]
end

function/s getLS370PIDparameters() // Units: No units
	// returns the PID parameters used.
	// the retruned values are comma seperated values.
	// P = {0.001 1000}, I = {0 10000}, D = {0 2500}
	nvar p_value,i_value,d_value
	string headers, payload, url, pid, token = "vMqyDIcB", command

	headers = "Content-Type: application/json"
	payload = "{\"command\": \"PID?\"}"
	sprintf command, "command?_at_=%s", token
	url = generateLS370URL(command)
	pid = queryLS370(url,headers,"v","post",payload=payload)
	p_value = str2num(stringfromlist(0,pid[1,inf],","))
	i_value = str2num(stringfromlist(1,pid[1,inf],","))
	d_value = str2num(stringfromlist(2,pid[1,inf],","))

	return pid
end

function getLS370controlmode() // Units: No units
	// returns the temperature control mode.
	// 1: PID, 3: Open loop, 4: Off
	nvar pid_mode, pid_led, mcheater_led
	string headers,payload,url,token = "vMqyDIcB", command,response

	headers = "Content-Type: application/json"
	payload = "{\"command\": \"CMODE?\"}"
	sprintf command, "command?_at_=%s", token
	url = generateLS370URL(command)
	response = queryLS370(url,headers,"v","post",payload=payload)
	pid_mode = str2num(response[1,inf])

	if(pid_mode == 1)
		pid_led = 1
		mcheater_led = 1
		PopupMenu mcheater, mode=1
		SetVariable mcheaterset, disable=2
	elseif(pid_mode == 3)
		pid_led = 0
		mcheater_led = 1
		PopupMenu mcheater, mode=1
		SetVariable mcheaterset, disable=0
	elseif(pid_mode == 4)
		pid_led = 0
		mcheater_led = 0
		PopupMenu mcheater, mode=2
		SetVariable mcheaterset, disable=0
	else
		print "Control mode not in supported modes, turning off heater!"
		sc_sleep(0.5)
		setLS370tempcontrolmode(4)
	endif
end

//// Get Functions - Directly from data base ////

// NOT implimented yet!

function getLS370tempDB(plate) // Units: mK
	// returns the temperature of the selected "plate".
	// avaliable plates on BF systems: mc (mixing chamber), still, magnet, 4K, 50K
	// avaliable plates on IGH systems: mc (mixing chamber), cold plate, still, 1K, sorb
	// data is queried directly from the SQL database
	string plate

end

function getLS370heaterpowerDB(heater) // Units: mW
	// returns the power of the selected heater.
	// avaliable heaters on BF systems: still (analog 2), mc
	// avaliable heaters on IGH systems: sorb (analog 1), still (analog 2), mc
	// data is queried directly from the SQL database
	string heater
end

function getLS370pressureDB(gauge) // Units: mbar
	// returns the pressure from the selected pressure gauge
	// avaliable gauges on BF systems: P1,P2,P3,P4,P5,P6
	// avaliable gauges on IGH systems: P1,P2,G1,G2,G3
	// data is queried directly from the SQL database
	string gauge
end

///////////////////////
//// Set Functions ////
//////////////////////

function setLS370tempcontrolmode(mode) // Units: No units
	// sets the temperature control mode
	// avaliable options are: off (4), PID (1) and Open loop (3)
	variable mode
	nvar pid_mode, pid_led, mcheater_led, mcheater_set, temp_set
	string command, payload, headers, url
	svar system, bfchannellookup, ighchannellookup
	variable channel, interval, maxcurrent

	strswitch(system)
		case "bfsmall":
			channel = whichlistitem("mc",bfchannellookup,";")
			channel = str2num(stringfromlist(channel+5,bfchannellookup,";"))
			break
		case "igh":
			channel = whichlistitem("mc",ighchannellookup,";")
			channel = str2num(stringfromlist(channel+5,ighchannellookup,";"))
			break
		case "bfbig":
			break
	endswitch

	if(mode == 1)
		pid_led = 1
		mcheater_led = 1
		PopupMenu mcheater, mode=1
		SetVariable mcheaterset, disable=2
		PopupMenu tempcontrol, mode=1
		interval = 10
		maxcurrent = estimateheaterrangeLS370(temp_set)
		setLS370PIDcontrol(channel,temp_set,maxcurrent)
		setLS370exclusivereader(channel,interval)
	elseif(mode == 3)
		pid_led = 0
		mcheater_led = 1
		PopupMenu mcheater, mode=1
		SetVariable mcheaterset, disable=0
		resetLS370exclusivereader()
		sc_sleep(0.5)
		setLS370cmode(mode)
	elseif(mode == 4)
		pid_led = 0
		mcheater_led = 0
		PopupMenu mcheater, mode=2, disable=0
		SetVariable mcheaterset, disable=0
		resetLS370exclusivereader()
		sc_sleep(0.5)
		setLS370cmode(mode)
		sc_sleep(0.5)
		turnoffLS370MCheater()
	else
		abort "Choose between: PID (1), Open loop (3) and off (4)"
	endif
	pid_mode = mode
end

function setLS370PIDcontrol(channel,setpoint,maxcurrent) //Units: mK, mA
	variable channel, setpoint, maxcurrent
	string payload, command, headers, url, token = "vMqyDIcB"
	nvar temp_set
	
	sprintf payload, "{ \"channel\": %d, \"set_point\": %g, \"max_current_ma\": %g, \"max_heater_level\": %s}", channel, setpoint/1000, maxcurrent, "8"
	headers = "Content-Type: application/json"
	sprintf command, "set-temperature-control-parameters?_at_=%s", token
	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
	temp_set = setpoint
end

function setLS370cmode(mode)
	//PID: 1, open loop: 3, off: 4
	variable mode
	string payload, command, headers, url, token = "vMqyDIcB"
	
	sprintf payload, "{\"command\": \"CMODE %d\"}", mode
	headers = "Content-Type: application/json"
	sprintf command, "command?_at_=%s", token
	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
end

function setLS370exclusivereader(channel,interval) // interval units: ms
	variable channel,interval
	string command, payload, headers, url, token = "vMqyDIcB"

	sprintf command, "set-exclusive-reader?_at_=%s", token
	sprintf payload, "{\"channel_label\": \"ch.%s\", \"interval_ms\": \"%s\"}", num2str(channel), num2str(interval)
	headers = "Content-Type: application/json"

	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
end

function resetLS370exclusivereader()
	string command, payload, headers, url, token = "vMqyDIcB"

	sprintf command, "reset-exclusive-reader?_at_=%s", token
	payload = "{}"
	headers = "Content-Type: application/json"

	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
end


function setLS370PIDtemp(temp) // Units: mK
	// sets the temperature for PID control and heater range
	variable temp
	string command,payload,headers,url,token = "vMqyDIcB"
	variable interval=10 //ms
	nvar temp_set
	svar bfchannellookup, ighchannellookup

	sprintf payload, "{\"command\": \"SETP %g\"}", temp/1000
	headers = "Content-Type: application/json"
	sprintf command, "command?_at_=%s", token
	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
	temp_set = temp
end

function setLS370heaterrange(range) // Units: AU
	// range must be a number between 0 and 8
	variable range
	string command,payload,headers,url,token = "vMqyDIcB"
	
	sprintf payload, "{\"command\": \"HTRRNG %d\"}", range
	sprintf command, "command?_at_=%s", token
	headers = "Content-Type: application/json"
	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
end

function setLS370PIDparameters(p,i,d) // Units: No units
	// set the PID parameters for the PID control loop
	// P = {0.001 1000}, I = {0 10000}, D = {0 2500}
	variable p,i,d
	nvar p_value,i_value,d_value
	string command,url,payload,headers,cmd, token = "vMqyDIcB"

	if(0.001 <= p && p <= 1000 && 0 <= i && i <= 10000 && 0 <= d && d <= 2500)
		sprintf cmd,"PID %s,%s,%s", num2str(p), num2str(i), num2str(d)
		headers = "Content-Type: application/json"
		sprintf payload, "{\"command\": \"%s\"}", cmd
		sprintf command, "command?_at_=%s", token
		url = generateLS370URL(command)
		writeLS370(url,payload,headers)
		p_value = p
		i_value = i
		d_value = d
	else
		abort "PID parameters out of range"
	endif
end

function setLS370heaterpower(heater,output) //Units: mW
	// sets the manual heater output
	// avaliable heaters on BF systems: mc,still
	// avaliable heaters on IGH: mc,still,sorb
	string heater
	variable output
	svar system, bfheaterlookup,ighheaterlookup
	nvar mcheater_set, stillheater_set, sorbheater_set
	variable channel, heater_idx
	string command, payload, url, headers, token = "vMqyDIcB"

	strswitch(system)
		case "bfsmall":
			heater_idx = whichlistitem(heater,bfheaterlookup,";")
			if(heater_idx < 0)
				printf "The requested heater (%s) doesn't exsist!", heater
				return -1.0
			else
				channel = str2num(stringfromlist(heater_idx+2,bfheaterlookup,";"))
			endif
			break
		case "igh":
			heater_idx = whichlistitem(heater,ighheaterlookup,";")
			if(heater_idx < 0)
				printf "The requested heater (%s) doesn't exsist!", heater
				return -1.0
			else
				channel = str2num(stringfromlist(heater_idx+3,ighheaterlookup,";"))
			endif
			break
		case "bfbig":
			break
	endswitch

	headers = "Content-Type: application/json"
	if(channel > 0)
		sprintf payload, "{\"analog_channel\":%d, \"power_mw\":%d}", channel, output
		sprintf command, "set-analog-output-power?_at_=%s", token
		if(channel > 1)
			stillheater_set = output
		else
			sorbheater_set = output
		endif
	else
		sprintf payload, "{\"power_mw\":%d}", output
		sprintf command, "set-heater-power?_at_=%s", token
		mcheater_set = output
	endif
	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
end

function turnoffLS370MCheater()
	// turns off MC heater.
	// this function can seem unnecessary, but is in some cases need
	// and therefore it is a good practise to always use it.
	string command, payload, headers, url, token = "vMqyDIcB"
	nvar pid_led, mcheater_led, pid_mode

	sprintf command, "turn-heater-off?_at_=%s", token
	headers = "Content-Type: application/json"
	payload = "{}"
	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
	pid_led = 0
	mcheater_led = 0
	pid_mode = 4
	PopupMenu mcheater, mode=2, disable=0, win=Lakeshore
	SetVariable mcheaterset, disable=0, win=Lakeshore
	PopupMenu tempcontrol, mode=2, win=Lakeshore
end

function toggleLS370magnetheater(onoff)
	// toggles the state of the magnet heater on BF #1.
	// it sets ANALOG 1 to -50% (-5V) in the "on" state
	// and 0% (0V) in the off state.
	// ANALOG 1 controls a voltage controlled switch!
	string onoff
	variable output
	nvar magnetheater_led
	svar system
	string command,url,payload,headers,cmd,token = "vMqyDIcB"

	if(cmpstr(system,"igh") == 0)
		abort "No heater installed on this system!"
	endif

	strswitch(onoff)
		case "on":
			output = -50.000
			magnetheater_led = 1
			break
		case "off":
			output = 0.000
			magnetheater_led = 0
			break
		default:
			// default is "off"
			print "Setting to \"off\""
			output = 0.000
			magnetheater_led = 0
			break
	endswitch

	headers = "Content-Type: application/json"
	sprintf cmd, "ANALOG 1,1,2,1,1,100.0,0.0,%g", output
	sprintf payload, "{\"command\":%s}", cmd
	sprintf command, "command?_at_=%s", token
	url = generateLS370URL(command)
	writeLS370(url,payload,headers)
end

////////////////////
//// Utillities ////
///////////////////

function estimateheaterrangeLS370(temp) // Units: mK
	// sets the heater range based on the wanted output
	// uses the range lookup table
	// avaliable ranges: 1,2,3,4,5,6,7,8 --> 0,10,30,95,501,1200,5000,10000 mK
	variable temp
	wave mcheatertemp_lookup
	make/o/n=8 heatervalues
	make/o/n=8 mintempabs
	make/o/n=8 mintemp
	variable maxcurrent


	heatervalues = mcheatertemp_lookup[p][1]
	mintempabs = abs(heatervalues-temp)
	mintemp = heatervalues-temp
	FindValue/v=(wavemin(mintempabs)) mintempabs
	if(mintemp[v_value] < 0)
		maxcurrent = mcheatertemp_lookup[v_value+1][0]
	else
		maxcurrent = mcheatertemp_lookup[v_value][0]
	endif

	return maxcurrent
end

function updateLS370GUI()
	// updates all control variables for the main control window
	getLS370controlmode()
	sc_sleep(0.5)
	getLS370PIDtemp()
	sc_sleep(0.5)
	getLS370PIDparameters()
	sc_sleep(0.5)
	getLS370heaterpower("mc")
	sc_sleep(0.5)
	getLS370heaterpower("still")
	//GetHeaterPowerDB("mc")
	//GetHeaterPowerDB("still")
end

// FIX pressure readings

function/s getLS370status()
	// returns loggable parameters to meta-data file
	svar system, ighgaugelookup
	string  buffer="", gauge=""
	variable i=0

	strswitch(system)
		case "bfsmall":
			buffer = addJSONKeyVal(buffer,"MC K",numVal = getLS370temp("mc"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"Still K",numVal = getLS370temp("still"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"4K Plate K",numVal = getLS370temp("4K"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"Magnet K",numVal = getLS370temp("magnet"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"50K Plate K",numVal = getLS370temp("50K"),fmtNum="%.3f")
//			for(i=1;i<7;i+=1)
//				gauge = "P"+num2istr(i)
//				buffer = addJSONKeyVal(buffer,gauge,numVal = GetPressureDB(gauge),fmtNum="%g")
//			endfor
			return addJSONKeyVal("","BF Small",strval = buffer)
		case "igh":
			buffer = addJSONKeyVal(buffer,"MC K",numVal = getLS370temp("mc"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"Cold Plate K",numVal = getLS370temp("cold plate"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"Still K",numVal = getLS370temp("still"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"1K Pot K",numVal = getLS370temp("1Kt"),fmtNum="%.3f")
			buffer = addJSONKeyVal(buffer,"Sorb K",numVal = getLS370temp("sorb"),fmtNum="%.3f")
//			for(i=1;i<6;i+=1)
//				gauge = stringfromlist(i,ighgaugelookup)
//				buffer = addJSONKeyVal(buffer,"P"+num2istr(i),numVal = GetPressureDB(gauge),fmtNum="%g")
//			endfor
			return addJSONKeyVal("","IGH",strval = buffer)
	endswitch
end

function setLS370system()
	// opens a control window and ask user to pick the correct system.
	// this is important, because it sets the correct url for the selected RPi.
	// if the wrong url is selected, you risk fucking up others experiment!!!
	string/g system

	execute("AskUserSystem()")
	PauseForUser AskUserSystem
end

function createLS370globals()
	// Create the needed global variables for driver

	// Create lookup tables
	string/g bfchannellookup = "mc;still;magnet;4K;50K;6;5;4;2;1"
	string/g ighchannellookup = "mc;cold plate;still;1K;sorb;3;6;5;2;1"
	string/g bfheaterlookup = "mc;still;0;2"
	string/g ighheaterlookup = "mc;still;sorb;0;2;1"
	string/g ighgaugelookup = "P1;P2;G1;G2;G3"
	make/o mcheatertemp_lookup = {{31.6e-3,100e-3,316e-3,1.0,3.16,10,31.6,100},{0,10,30,95,350,1201,1800,10000}} // mA,mK

	// Create variables for control window
	variable/g pid_led = 0
	variable/g mcheater_led = 0
	variable/g stillheater_led = 0
	variable/g magnetheater_led = 0
	variable/g sorbheater_led = 0
	variable/g temp_set = 0
	variable/g mcheater_set = 0
	variable/g stillheater_set = 0
	variable/g sorbheater_set = 0
	variable/g p_value = 10
	variable/g i_value = 5
	variable/g d_value = 0
	variable/g pid_mode = 4
end

function/s generateLS370URL(command)
	// Generate the command URL
	string command
	svar system
	string url

	strswitch(system)
		case "bfsmall":
			sprintf url, "http://bfsmall-wifi:7777/api/v1/%s", command
			break
		case "igh":
			sprintf url, "http://qdash.qdot.lab:7777/api/v1/%s", command
			break
		case "bfbig":
			break
		endswitch
	return url
end

function/s GenerateDBURL(data_type,data_label)
	string data_type,data_label
	svar system
	string query_url

	return query_url
end

///////////////////////
//// Communication ////
//////////////////////

function/s writeLS370(url,payload,headers)
	string url,payload,headers
	string response, error

	URLRequest /TIME=5.0 /DSTR=payload url=url, method=post, headers=headers

	if (V_flag == 0)    // No error
		response = S_serverResponse // response is a JSON string
		if (V_responseCode != 200)  // 200 is the HTTP OK code
		   printf error, "[ERROR]: %s\r", getJSONvalue(response, "error")
		   return ""
		else
			return "" // do nothing
		endif
   else
        abort "HTTP connection error."
   endif
end

function/s queryLS370(url,headers,responseformat,method,[payload])
	// function takes four strings: url,payload,headers,responseformat
	// url most be generated by GenerateURL(), paylod is a json string containing "key:value" pairs
	// headers is always "Content-Type: application/json" and responseformat is the "key" of the returned data.
	// the returned value is a string.
	string url,headers,responseformat,method,payload
	variable ok
	string response, error, keys
	
	if(cmpstr(method,"get")==0)
		URLRequest /TIME=5.0 url=url, method=get, headers=headers
	elseif(cmpstr(method,"post")==0 && !paramisdefault(payload))
		URLRequest /TIME=5.0 /DSTR=payload url=url, method=post, headers=headers
	else
		abort "Not a supported method or you forgot to add a payload."
	endif

	if (V_flag == 0)    // No error
		response = S_serverResponse // response is a JSON string
		if (V_responseCode != 200)  // 200 is the HTTP OK code
		   printf error, "[ERROR]: %s\r", getJSONvalue(response, "error")
		   return ""
		else
		    keys = getJSONkeys(response) // if heater output is 0, we only get time back!
		    if(findlistitem(responseformat,keys,",",0) == -1)
		    	return "0"
		    else
		    	return getJSONvalue(response, responseformat)
		    endif
		endif
   else
        printf error, "[ERROR]: HTTP connection error\r"
        return ""
   endif
end

function/s queryLS370DB(query_url)
	string query_url
	string headers,url,response

	headers = "Content-Type: application/x-www-form-urlencoded"
	sprintf url, "http://qdot-server.phas.ubc.ca:8086/query? --data_urlencode \"db=test\" --data_urlencode \"%s\"", query_url


	URLRequest /TIME=5.0 url=url, method=get, headers=headers

	if (V_flag == 0)    // No error
		if (V_responseCode != 200)  // 200 is the HTTP OK code
		    print "Reading failed!"
		    return num2str(-1.0)
		else
		    response = S_serverResponse
		    print response
		endif
   else
        print "HTTP connection error."
        return num2str(-1.0)
   endif
end

/////////////////////////
//// Control Windows ////
////////////////////////

//// Main control window ////

window lakeshore_window() : Panel
	PauseUpdate; Silent 1 // building window
	if(cmpstr(system,"bfsmall") == 0 || cmpstr(system,"bfbig") == 0)
		NewPanel /W=(0,0,380,325) /N=Lakeshore
	else
		NewPanel /W=(0,0,380,350) /N=Lakeshore
	endif
	ModifyPanel frameStyle=2
	SetDrawLayer UserBack
	SetDrawEnv fsize= 25,fstyle= 1
	DrawText 80, 45,"Lakeshore (LS370)" // headline

	// PID settings
	PopupMenu tempcontrol, pos={20,50},size={250,50},mode=2,title="\\Z16Temperature Control:",value=("On;Off"), proc=tempcontrol_control
	ValDisplay pidled, pos={310,50}, size={53,25}, mode=2,value=pid_led, zerocolor=(65535,0,0), limits={0,1,-1}, highcolor=(65535,0,0),lowcolor=(0,65535,0),barmisc={0,0},title="\\Z14PID"
	SetVariable tempset, pos={20,80},size={300,50},value=temp_set,title="\\Z16Temperature Setpoint (mK):",limits={0,300000,0},proc=tempset_control
	SetVariable P, pos={20,110},size={70,50},value=p_value,title="\\Z16P:",limits={0.001,1000,0}
	SetVariable I, pos={100,110},size={67,50},value=i_value,title="\\Z16I:",limits={0,10000,0}
	SetVariable D, pos={177,110},size={70,50},value=d_value,title="\\Z16D:",limits={0,2500,0}
	Button PIDUpdate, pos={257,110},size={100,20},title="\\Z14Update PID",proc=pid_control
	DrawLine 10,140,370,140

	// MC heater settings
	PopupMenu mcheater, pos={20,150},size={250,50},mode=2,title="\\Z16MC Heater:",value=("On;Off"), proc=mcheater_control
	ValDisplay mcheaterled, pos={300,150}, size={65,20}, mode=2,value=mcheater_led, zerocolor=(65535,0,0), limits={0,1,-1}, highcolor=(65535,0,0),lowcolor=(0,65535,0),barmisc={0,0},title="\\Z10MC\rHeater"
	SetVariable mcheaterset, pos={20,180},size={250,50},value=mcheater_set,title="\\Z16Heater Setpoint (mW):",limits={0,1000,0},proc=mcheaterset_control
	DrawLine 10,210,370,210
	// Still heater settings
	PopupMenu stillheater, pos={20,220},size={250,50},mode=2,title="\\Z16Still Heater:",value=("On;Off"), proc=stillheater_control
	ValDisplay stillheaterled, pos={300,220}, size={65,20}, mode=2,value=stillheater_led, zerocolor=(65535,0,0), limits={0,1,-1}, highcolor=(65535,0,0),lowcolor=(0,65535,0),barmisc={0,0},title="\\Z10Still\rHeater"
	SetVariable stillheaterset, pos={20,250},size={250,50},value=stillheater_set,title="\\Z16Heater Setpoint (mW):",limits={0,1000,0},proc=stillheaterset_control
	DrawLine 10,280,370,280
	if(cmpstr(system,"bfsmall") == 0 || cmpstr(system,"bfbig") == 0)
			// Magnet heater settings
			PopupMenu magnetheater, pos={20,290},size={250,50},mode=2,title="\\Z16Magnet Heater:",value=("On;Off"), proc=magnetheater_control
			ValDisplay magnetheaterled, pos={297,290}, size={68,20}, mode=2,value=magnetheater_led, zerocolor=(65535,0,0), limits={0,1,-1}, highcolor=(65535,0,0),lowcolor=(0,65535,0),barmisc={0,0},title="\\Z10Magnet\rHeater"
	else
		if(cmpstr(system,"igh") == 0)
			// Sorb heater settings
			PopupMenu sorbheater, pos={20,290},size={250,50},mode=2,title="\\Z16Sorb Heater:",value=("On;Off"), proc=sorbheater_control
			ValDisplay sorbheaterled, pos={300,290}, size={65,20}, mode=2,value=sorbheater_led, zerocolor=(65535,0,0), limits={0,1,-1}, highcolor=(65535,0,0),lowcolor=(0,65535,0),barmisc={0,0},title="\\Z10Sorb\rHeater"
			SetVariable sorbheaterset, pos={20,320},size={250,50},value=sorbheater_set,title="\\Z16Heater Setpoint (mW):",limits={0,1000,0},proc=sorbheaterset_control
		else
			abort "System not selected!"
		endif
	endif
endmacro

function tempcontrol_control(action,popnum,popstr) : PopupMenuControl
	string action
	variable popnum
	string popstr
	variable mode
	nvar pid_led, mcheater_led, pid_mode

	strswitch(popstr)
		case "On":
			pid_led = 1
			mcheater_led = 1
			PopupMenu mcheater, mode=1, disable=2
			SetVariable mcheaterset, disable=2
			mode = 1
			break
		case "Off":
			pid_led = 0
			mcheater_led = 0
			PopupMenu mcheater, mode=2, disable=0
			SetVariable mcheaterset, disable=0
			mode = 4
			break
	endswitch
	setLS370tempcontrolmode(mode)
	pid_mode = mode
end

function tempset_control(action,varnum,varstr,varname) : SetVariableControl
	string action
	variable varnum
	string varstr, varname

	setLS370PIDtemp(varnum) // mK
end

function pid_control(action) : ButtonControl
	string action
	nvar p_value,i_value,d_value

	setLS370PIDparameters(p_value,i_value,d_value)
end

function mcheater_control(action,popnum,popstr) : PopupMenuControl
	string action
	variable popnum
	string popstr
	nvar mcheater_led, mcheater_set

	strswitch(popstr)
		case "On":
			mcheater_led = 1
			setLS370tempcontrolmode(3) // set to "open loop"
			sc_sleep(0.5)
			setLS370heaterpower("mc",mcheater_set) //mW
			break
		case "Off":
			mcheater_led = 0
			turnoffLS370MCheater()
			break
	endswitch
end

function mcheaterset_control(action,varnum,varstr,varname) : SetVariableControl
	string action
	variable varnum
	string varstr, varname
	nvar mcheater_led, pid_mode

	setLS370heaterpower("mc",varnum)
	if(varnum > 0)
		mcheater_led = 1
		pid_mode = 3
		PopupMenu mcheater, mode=1
	else
		mcheater_led = 0
		pid_mode = 4
		PopupMenu mcheater, mode=0
	endif
end

function stillheater_control(action,popnum,popstr) : PopupMenuControl
	string action
	variable popnum
	string popstr
	nvar stillheater_led, stillheater_set

	strswitch(popstr)
		case "On":
			stillheater_led = 1
			setLS370heaterpower("still",stillheater_set) //mW
			break
		case "Off":
			stillheater_led = 0
			setLS370heaterpower("still",0) //mW
			break
	endswitch
end

function stillheaterset_control(action,varnum,varstr,varname) : SetVariableControl
	string action
	variable varnum
	string varstr, varname
	nvar stillheater_led

	setLS370heaterpower("still",varnum) //mW
	if(varnum > 0)
		stillheater_led = 1
		PopupMenu stillheater, mode=1
	else
		stillheater_led = 0
		PopupMenu stillheater, mode=0
	endif
end

function magnetheater_control(action,popnum,popstr) : PopupMenuControl
	string action
	variable popnum
	string popstr
	nvar magnetheater_led

	strswitch(popstr)
		case "On":
			magnetheater_led = 1
			toggleLS370magnetheater("on")
			break
		case "Off":
			magnetheater_led = 0
			toggleLS370magnetheater("off")
			break
	endswitch
end

function sorbheater_control(action,popnum,popstr) : PopupMenuControl
	string action
	variable popnum
	string popstr
	nvar sorbheater_led, sorbheater_set

	strswitch(popstr)
		case "On":
			sorbheater_led = 1
			setLS370heaterpower("sorb",sorbheater_set) //mW
			break
		case "Off":
			sorbheater_led = 0
			setLS370heaterpower("sorb",0) //mW
			break
	endswitch
end

function sorbheaterset_control(action,varnum,varstr,varname) : SetVariableControl
	string action
	variable varnum
	string varstr, varname
	nvar sorbheater_led

	setLS370heaterpower("sorb",varnum) //mW
	if(varnum > 0)
		sorbheater_led = 1
		PopupMenu sorbheater, mode=1
	else
		sorbheater_led = 0
		PopupMenu sorbheater, mode=0
	endif
end

//// System set control wondow ////

window AskUserSystem() : Panel
	PauseUpdate; Silent 1 // building window
	NewPanel /W=(100,100,400,200) // window size
	ModifyPanel frameStyle=2
	SetDrawLayer UserBack
	SetDrawEnv fsize= 25,fstyle= 1
	DrawText 40, 40,"Initialize Lakeshore" // Headline
	PopupMenu SelectSystem, pos={60,60},size={250,50},mode=4,title="\\Z16Select System:",value=("Blue Fors #1;IGH;Blue Fors #2"), proc=selectsystem_control
endmacro

function selectsystem_control(action,popnum,popstr) : PopupMenuControl
	string action
	variable popnum
	string popstr
	svar system

	strswitch(popstr)
		case "Blue Fors #1":
			system = "bfsmall"
			dowindow/k AskUserSystem
			break
		case "IGH":
			system = "igh"
			dowindow/k AskUserSystem
			break
		case "Blue Fors #2":
			system = "bfbig"
			print "No support for BF#2 yet!"
			dowindow/k AskUserSystem
			execute("AskUserSystem()")
			break
	endswitch
end
