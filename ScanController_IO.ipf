#pragma rtGlobals=1		// Use modern global access method.

/// this procedure contains all of the functions that
/// scan controller needs for file I/O and custom formatted string handling
/// currently that includes -- saving IBW and HDF5 files
///                            reading/writing/parsing JSON
///                            loading/saving ini config files

//////////////////////////////
/// SAVING EXPERIMENT DATA ///
//////////////////////////////

///// templates for InitSaveFiles_, SaveSingleWave_, EndSaveFiles_ /////

function sc_initSaveTemp([msg])
	// template for InitSaveFiles_XX
	string msg
end

function sc_saveSingleTemp(wn)
	// template for SaveSingleWave_XX
	string wn
end

function sc_endSaveTemp()
	// template for EndSaveFiles_XX
end

///// generic /////

function /S recordedWaveArray()
	wave /T sc_RawWaveNames, sc_CalcWaveNames
	wave sc_RawRecord, sc_CalcRecord
	string swave=""
	variable i=0
	do
		if(strlen(sc_RawWaveNames[i])!=0 && sc_RawRecord[i]==1)
			swave += "\""+sc_RawWaveNames[i]+"\", "
		endif
		i+=1
	while(i<numpnts(sc_RawWaveNames))

	i=0
	do
		if(strlen(sc_CalcWaveNames[i])!=0 && sc_CalcRecord[i]==1)
			swave += "\""+sc_CalcWaveNames[i]+"\", "
		endif
		i+=1
	while(i<numpnts(sc_CalcWaveNames))

	return "["+swave[0,strlen(swave)-3]+"]"
end

///// HDF5 /////

// get meta data

function /s json2hdf5attributes(jstr, obj_name, h5id)
	// writes key/value pairs from jstr as attributes of "obj_name"
	// in the hdf5 file or group identified by h5id
	string jstr, obj_name
	variable h5id

	make /FREE /T /N=1 str_attr = ""
	make /FREE /N=1 num_attr = 0

	// loop over keys
	string keys = getJSONkeys(jstr)
	variable j = 0, numKeys = ItemsInList(keys, ",")
	string currentKey = "", currentVal = ""
	string group = ""
	for(j=0;j<numKeys;j+=1)
		currentKey = StringFromList(j, keys, ",")
		if(strsearch(currentKey, ":", 0)==-1)
			currentVal = getJSONValue(jstr, currentKey)
			if(findJSONtype(currentVal)==0)
				num_attr[0] = str2num(currentVal)
				HDF5SaveData /A=currentKey num_attr, h5id, obj_name
			else
				str_attr[0] = currentVal
				HDF5SaveData /A=currentKey str_attr, h5id, obj_name
			endif
		endif
	endfor

end

// save waves and experiment

function initSaveFiles_hdf5([msg])
	//// create/open any files needed to save data
	//// also save any global meta-data you want
	string msg
	if(paramisdefault(msg)) // save meta data
		msg=""
	endif

	nvar filenum
	string filenumstr = ""
	sprintf filenumstr, "%d", filenum
	string /g h5name = "dat"+filenumstr+".h5"

	// Open HDF5 file
	variable /g hdf5_id
	HDF5CreateFile /P=data hdf5_id as h5name

	// save x and y arrays
	nvar sc_is2d
	HDF5SaveData /IGOR=-1 /TRAN=1 /WRIT=1 $"sc_xdata" , hdf5_id, "x_array"
	if(sc_is2d)
		HDF5SaveData /IGOR=-1 /TRAN=1 /WRIT=1 $"sc_ydata" , hdf5_id, "y_array"
	endif

	// Create metadata group
	variable /G metadata_group_ID
	HDF5CreateGroup hdf5_id, "metadata", metadata_group_ID
	json2hdf5attributes(getExpStatus(msg=msg), "metadata", hdf5_id) // add experiment metadata

	// Create config group
	svar sc_current_config
	variable /G config_group_ID
	HDF5CreateGroup hdf5_id, "config", config_group_ID
	json2hdf5attributes(JSONfromFile("config", sc_current_config), "config", hdf5_id) // add current scancontroller config

	// Create logs group
	svar sc_current_config
	variable /G logs_group_ID
	HDF5CreateGroup hdf5_id, "logs", logs_group_ID
	json2hdf5attributes(getEquipLogs(), "logs", hdf5_id) // add current scancontroller config

end

function saveSingleWave_hdf5(wn)
	// wave with name 'filename' as filename.ibw
	string wn
	nvar hdf5_id

	HDF5SaveData /IGOR=-1 /TRAN=1 /WRIT=1 /Z $wn , hdf5_id
	if (V_flag != 0)
		Print "HDF5SaveData failed: ", wn
		return 0
	endif

	 // add wave status JSON string as attribute
	 nvar hdf5_id
	 json2hdf5attributes(getWaveStatus(wn), wn, hdf5_id)
end

function endSaveFiles_hdf5()
	//// close any files that were created for this dataset

	nvar filenum
	string filenumstr = ""
	sprintf filenumstr, "%d", filenum
	string /g h5name = "dat"+filenumstr+".h5"

	// close metadata group
	nvar metadata_group_id
	HDF5CloseGroup /Z metadata_group_id
	if (V_flag != 0)
		Print "HDF5CloseGroup Failed: ", "metadata"
	endif

	// close config group
	nvar config_group_id
	HDF5CloseGroup /Z config_group_id
	if (V_flag != 0)
		Print "HDF5CloseGroup Failed: ", "config"
	endif

	// close HDF5 file
	nvar hdf5_id
	HDF5CloseFile /Z hdf5_id
	if (V_flag != 0)
		Print "HDF5CloseFile failed: ", h5name
	endif

end

///// IBW /////

// save waves and experiment

function initSaveFiles_ibw([msg])
	//// create/open any files needed to save data
	//// also save any global meta-data you want

	string msg
	if(paramisdefault(msg)) // save meta data
		msg=""
	endif

	SaveScanComments(msg=msg)

end

function saveSingleWave_ibw(wn)
	// wave with name 'filename' as filename.ibw
	string wn

	nvar filenum
	string filenumstr = ""
	sprintf filenumstr, "%d", filenum
	string filename =  "dat" + filenumstr + wn

	Save/C/P=data $filename;

	svar sc_x_label, sc_y_label
	SaveInitialWaveComments(wn, x_label=sc_x_label, y_label=sc_y_label)
end

function endSaveFiles_ibw()
	//// close any files that were created for this dataset
	//// we don't need to do anything here
end

// save comments files

function /S saveScanComments([msg])
	// msg can be any normal string, it will be saved as a JSON string value

	string msg
	string buffer="", jstr=""
	jstr += getExpStatus() // record date, time, wave names, time elapsed...

	if (!paramisdefault(msg) && strlen(msg)!=0)
		jstr = addJSONkeyvalpair(jstr, "comments", TrimString(msg), addQuotes = 1)
	endif

	jstr = addJSONkeyvalpair(jstr, "logs", getEquipLogs())

	//// save file ////
	nvar filenum
	string extension, filename
	extension = "." + num2istr(unixtime()) + ".winf"
	filename =  "dat" + num2istr(filenum) + extension
	writeJSONtoFile(jstr, filename, "winfs")

	return jstr
end

function /s str2WINF(datname, s)
	// string s to winf file
	//filename = dat<filenum><datname>.<unixtime>.winf
	string datname, s
	variable refnum
	nvar filenum
	string filenumstr = ""
	sprintf filenumstr, "%d", filenum
	string extension, filename
	extension = "." + num2istr(unixtime()) + ".winf"
	filename =  "dat" + filenumstr + datname + extension
	open /A/P=winfs refnum as filename

	do
		if(strlen(s)<500)
			fprintf refnum, "%s", s
			break
		else
			fprintf refnum, "%s", s[0,499]
			s = s[500,inf]
		endif
	while(1)
	close refnum

	return filename
end

function /S SaveInitialWaveComments(datname, [title, x_label, y_label, z_label, x_multiplier, y_multiplier, z_multiplier, display_thumbnail])
	variable  x_multiplier, y_multiplier, z_multiplier
	string datname, title, x_label, y_label, z_label, display_thumbnail
	string buffer="", comments=""

	// save waveStatus
	string jstr = getWaveStatus(datname)

	comments += prettyJSONfmt(jstr) + "\r\r" // record date, time, wave names, time elapsed...

	// save plot commands
	// these cannot be JSON strings because of the way ..../measurements looks for them
	// i'm ignoring this in hopes that we can move to HDF5 instead of dealing with it
	string plotcmds=""
	if (paramisdefault(title))
		title = ""
	endif
	plotcmds+="$$ title = "+title+"\r"

	if (paramisdefault(x_label))
		x_label = ""
	endif
	plotcmds+="$$ x_label = "+x_label+"\r"

	if (paramisdefault(y_label))
		y_label = ""
	endif
	plotcmds+="$$ y_label = "+y_label+"\r"

	if (paramisdefault(z_label))
		z_label = ""
	endif
	plotcmds+="$$ z_label = "+z_label+"\r"

	if (paramisdefault(x_multiplier))
		x_multiplier = 1.0
	endif
	plotcmds+="$$ x_multiplier = "+num2str(x_multiplier)+"\r"

	if (paramisdefault(y_multiplier))
		y_multiplier = 1.0
	endif
	plotcmds+="$$ y_multiplier = "+num2str(y_multiplier)+"\r"

	if (paramisdefault(z_multiplier))
		z_multiplier = 1.0
	endif
	plotcmds+="$$ z_multiplier = "+num2str(z_multiplier)+"\r"

	if (paramisdefault(display_thumbnail))
		display_thumbnail = "False"
	endif
	plotcmds+="$$ display_thumbnail = "+display_thumbnail+"\r"

	comments+=plotcmds

	str2WINF(datname, comments)
end


////////////////////////
//// JSON functions ////
////////////////////////

//// JSON util ////

function/s numToBool(val)
	variable val
	if(val==1)
		return "true"
	elseif(val==0)
		return "false"
	else
		return ""
	endif
end

function boolToNum(str)
	string str
	if(StringMatch(LowerStr(str), "true")==1)
		// use string match to ignore whitespace
		return 1
	elseif(StringMatch(LowerStr(str), "false")==1)
		return 0
	else
		return -1
	endif
end

function/s textWaveToStrArray(w)
	// returns a JSON array and makes sure quotes and commas are parsed correctly.
	wave/t w
	string list, checkStr, escapedStr
	variable i=0

	wfprintf list, "\"%s\";", w
	for(i=0;i<itemsinlist(list,";");i+=1)
		checkStr = stringfromlist(i,list,";")
		if(countQuotes(checkStr)>2)
			escapedStr = escapeJSONstr(checkStr)
			list = removelistitem(i,list,";")
			list = addlistitem(escapedStr,list,";",i)
		endif
	endfor
	list = replacestring(";",list,",")
	return "["+list[0,strlen(list)-2]+"]"
end

function countQuotes(str)
	// count how many quotes are in the string
	// +1 for "
	// escaped quotes are ignored
	string str
	variable quoteCount = 0, i = 0, escaped = 0
	for(i=0; i<strlen(str); i+=1)

		// check if the current character is escaped
		if(i!=0)
			if( CmpStr(str[i-1], "\\") == 0)
				escaped = 1
			else
				escaped = 0
			endif
		endif

		// count opening brackets
		if( CmpStr(str[i], "\"" ) == 0 && escaped == 0)
			quoteCount += 1
		endif

	endfor
	return quoteCount
end

function/s escapeInnerQuotes(str)
	string str
	variable i, escaped
	string dummy="", newStr=""

	for(i=1; i<strlen(str)-1; i+=1)

		// check if the current character is escaped
		if(cmpStr(str[i-1], "\\") == 0)
			escaped = 1
		else
			escaped = 0
		endif

		// find extra quotes
		dummy = str[i]
		if(cmpStr(dummy, "\"" )==0 && escaped==0)
			dummy = "\\"+dummy
		endif
		newStr = newStr+dummy
	endfor
	return newStr
end

function/s numericWaveToBoolArray(w)
	// returns a JSON array
	wave w
	string list = "["
	variable i=0

	for(i=0; i<numpnts(w); i+=1)
		list += numToBool(w[i])+","
	endfor

	return list[0,strlen(list)-2] + "]"
end

function/s unescapeJSONstr(JSONstr)
	string JSONstr
	variable escapePos

	do
		escapePos =strsearch(JSONstr,"\\",0)
		if(escapePos > 0)
			JSONstr = replacestring(JSONstr[escapePos,escapePos+4],JSONstr,num2char(str2num(JSONstr[escapePos+1,escapePos+4])))
		endif
	while(escapePos > 0)

	if(mod(countQuotes(JSONstr),2)==1)
		JSONstr = JSONstr[0,strlen(JSONstr)-2]
	endif

	return JSONstr
end

function/s escapeJSONstr(JSONstr)
	string JSONstr
	variable escapePos, i=0
	string checkStr, checklist = "\";," // add more if needed

	checkStr = JSONstr[1,strlen(JSONstr)-2]
	for(i=0;i<itemsinlist(checklist,";");i+=1)
		do
			escapePos =strsearch(checkStr,stringfromlist(i,checklist,";"),0)
			if(escapePos > 0)
					checkStr = replacestring(checkStr[escapePos],checkStr,dectoescapedhexstr(char2num(checkStr[escapePos])))
			endif
		while(escapePos > 0)
	endfor

	return "\""+checkStr+"\""
end

function/s dectoescapedhexstr(num,[add_slash])
	variable num, add_slash
	string hexstring, hextable = "0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F"

	if(paramisdefault(add_slash))
		hexstring = "\0x"
	else
		hexstring = "0x"
	endif

	return hexstring+num2str(floor(num/16))+stringfromlist(num-floor(num/16)*16,hextable,",")
end

function/s readJSONobject(jstr)
	// given a string starting with {
	// return everything upto and including the matching }
	// ignores escaped brackets "\{" and "\}"
	string jstr
	variable i=0, openBrackets=0, startPos=-1, endPos=-1, escaped=0

	jstr = TrimString(jstr) // just in case this didn't already happen

	for(i=0; i<strlen(jstr); i+=1)
		// check if the current character is escaped
		if(i!=0)
			if( CmpStr(jstr[i-1], "\\") == 0)
				escaped = 1
			else
				escaped = 0
			endif
		endif

		// count opening brackets
		if( CmpStr(jstr[i], "{" ) == 0 && escaped == 0)
			openBrackets+=1
			if(startPos==-1)
				startPos = i
			endif
		endif

		// count closing brackets
		if( CmpStr(jstr[i], "}" ) == 0 && escaped == 0)
			openBrackets-=1
			if(openBrackets==0)
				// found the last closing bracket
				endPos = i
				break
			endif
		endif
	endfor

	if(openBrackets!=0 || startPos==-1 || endPos==-1)
		print "[WARNING] This JSON string is bullshit: ", jstr
		return ""
	endif

	return jstr[startPos, endPos]
end

function findJSONtype(JSONvalue,[JSONstr])
	// Must call "JSONSimple" on a valid JSON string before this function!
	string JSONvalue, JSONstr
	variable i=0

	if(!paramisdefault(JSONstr))
		JSONsimple JSONstr
	endif
	wave/t t_tokentext
	wave w_tokenparent, w_tokentype, w_tokensize

	// RETURN TYPES:
	// 0 -- primitive
	// 1 -- object
	// 2 -- array
	// 3 -- string

	JSONvalue = TrimString(JSONvalue) // trim leading/trailing whitespace
	if(strlen(JSONvalue)==0 )
		return -1
	endif

	JSONvalue = stripJSONquotes(JSONvalue)

	for(i=0;i<numpnts(t_tokentext);i+=1)
		if(cmpstr(t_tokentext[i],JSONvalue)==0)
			return w_tokentype[i]
		endif
	endfor
	return -1
end

function/s stripJSONquotes(JSONstr)
	string JSONstr

	if(cmpstr(JSONstr[0],"\"")==0)
		JSONstr = JSONstr[1,strlen(JSONstr)-2]
	endif
	return JSONstr
end

//// load from/write to file ////

function/s JSONfromfile(path, filename)
	// read JSON string from filename in path
	string path, filename
	variable refNum
	string buffer = "", JSONstr = ""

	open /r/z/p=$path refNum as filename
	if(V_flag!=0)
		print "[ERROR]: Could not read JSON from: "+filename
		return ""
	endif

	do
		FReadLine refNum, buffer
		if(strlen(buffer)==0)
			break
		endif
		JSONstr+=buffer
	while(1)
	close refNum

	return JSONstr
end

function writeJSONtoFile(JSONstr, filename, path)
	string JSONstr, filename, path
	variable refNum=0

	// write jstr to filename
	// add whitespace to make it easier to read
	// this is expected to be a valid json str
	// it will be a disaster otherwise

	JSONstr = prettyJSONfmt(JSONstr)

	open /z/p=$path refNum as filename

	do
		if(strlen(JSONstr)<500)
			fprintf refnum, "%s", JSONstr
			break
		else
			fprintf refnum, "%s", JSONstr[0,499]
			JSONstr = JSONstr[500,inf]
		endif
	while(1)

	close refNum
end

//// create JSON strings ////

function/s addJSONkeyvalpair(JSONstr,key,value,[addquotes])
	// returns a valid JSON string with a new key,value pair added.
	// if JSONstr is empty, start a new JSON object
	string JSONstr, key, value
	variable addquotes

	if(!paramisdefault(addquotes))
		value = "\""+value+"\""
	endif

	if(strlen(JSONstr)==0)
		JSONstr = "{"
	else
		JSONstr = readJSONobject(JSONstr)
		JSONstr = JSONstr[0,strlen(JSONstr)-2]+","
	endif

	return JSONstr+"\""+key+"\":"+value+"}"
end

function/s getJSONindent(level)
	// returning whitespace for formatting JSON strings
	variable level

	variable i=0
	string output = ""
	for(i=0;i<level;i+=1)
		output += "  "
	endfor

	return output
end

function/s getJSONclosingbracket(num)
	// return a closing bracket "}"
	// if num==1 add a comma
	variable num
	variable i=0
	string bracket="}"

	if(num)
		bracket += ","
	endif

	return bracket
end

function/s prettyJSONfmt(jstr)
	// returns a "pretty" JSON str
	string jstr
	string outStr="{\r", buffer="", printkey="", strVal="", key="", parents=""
	variable i=0, j=0, k=0, level = 0, delta_level

	// get JSON keys
	string keylist = getJSONkeys(jstr)
	for(i=0;i<itemsinlist(keylist,",");i+=1) // loop over keys

		key = stringfromlist(i, keylist, ",")
		printkey = stringfromlist(itemsinlist(key, ":")-1, key, ":")

		// if delta_level is > 0, then the previous object(s) must be closed.
		delta_level = level-itemsinlist(key, ":")
		if(i!=0 && delta_level>0)
			for(k=delta_level;k>0;k-=1)
				outStr= outStr[0,strlen(outStr)-3] + "\r" + getJSONindent(delta_level-1+k) + getJSONclosingbracket(k)+"\r"
			endfor
		endif

		level = itemsinlist(key, ":")
		if(level>1)
			for(j=0;j<level-1;j+=1)
				parents = addlistitem(stringfromlist(j,key,":"),parents,",")
			endfor
		else
			parents = ""
		endif
		strVal = getJSONValue(jstr, printkey, parents=parents)

		switch(findJSONtype(strVal))
			case 1:
				// this is an object! don't put the value in, it will contain keys and be handled in subsequent calls
				outStr += getJSONindent(level)+"\""+printkey+"\""+": {\r"
				break
			case 2:
				outStr += getJSONindent(level)+"\""+printkey+"\""+": "+strVal+",\r"
				break
			case 3:
				outStr += getJSONindent(level)+"\""+printkey+"\""+": "+strVal+",\r"
				break
			case 0:
				outStr += getJSONindent(level)+"\""+printkey+"\""+": "+strVal+",\r"
				break
			case -1:
				strVal = ""
				outStr += getJSONindent(level)+"\""+printkey+"\""+": "+strVal+",\r"
				break
		endswitch
	endfor

	outStr = outStr[0,strlen(outStr)-3]+"\r}" // fix trailing comma trouble

	return outStr
end

/// parse JSON strings to variables/waves ///

function loadtextJSONfromkeys(keys,destinations,[children])
	// parse key,value pairs to text waves
	string keys, destinations, children
	variable i=0, j=0, index
	string valuelist
	wave/t t_tokentext
	wave w_tokenparent, w_tokensize, w_tokentype

	if(paramisdefault(children))
		children = ""
	endif

	if(itemsinlist(keys,",")!=itemsinlist(destinations,","))
		print "[ERROR]: loadtextJSONfromkeys() Number of keys doesn't match numbers of destination waves!"
		return -1
	else
		for(i=0;i<itemsinlist(keys,",");i+=1)
			index = getJSONkeyindex(stringfromlist(i,keys,","),t_tokentext)
			valuelist = extractJSONvalues(index,children=stringfromlist(i,children,";"))
			make/o/t/n=(itemsinlist(valuelist,",")) $stringfromlist(i,destinations,",") = stringfromlist(p,valuelist,",")
			wave/t wref = $stringfromlist(i,destinations,",")
			for(j=0;j<itemsinlist(valuelist,",");j+=1)
				wref[j] = unescapeJSONstr(wref[j])
			endfor
		endfor
	endif
end

function loadbooleanJSONfromkeys(keys,destinations,[children])
	// parse key,value pairs to boolean waves
	string keys, destinations, children
	variable i=0, numchildren, index
	string valuelist
	wave/t t_tokentext
	wave w_tokenparent, w_tokensize, w_tokentype

	if(paramisdefault(children))
		numchildren = 0
		children = ""
	endif

	if(itemsinlist(keys,",")!=itemsinlist(destinations,","))
		print "[ERROR]: Config load falied! Number of keys doesn't match numbers of destination waves!"
		return -1
	else
		for(i=0;i<itemsinlist(keys,",");i+=1)
			index = getJSONkeyindex(stringfromlist(i,keys,","),t_tokentext)
			valuelist = extractJSONvalues(index,children=stringfromlist(i,children,";"))
			make/o/n=(itemsinlist(valuelist,",")) $stringfromlist(i,destinations,",") = booltonum(stringfromlist(p,valuelist,","))
		endfor
	endif
end

function/s extractJSONvalues(parentindex,[children])
	// returns a comma seperated list of all values belonging to the key with the index=parentindex
	// or the values belonging to the lowest level child, if children are parsed.
	// children must be a comma seperated string list
	variable parentindex
	string children
	wave/t t_tokentext
	wave w_tokenparent, w_tokensize
	string valuelist=""
	variable i=0,j=0, childindex, newchildindex, numchildren, offset=0

	// correct index based on the number of children
	if(paramisdefault(children))
		numchildren = 0
		childindex=parentindex
	else
		numchildren = itemsinlist(children,",")
		childindex=parentindex+mod(numchildren,2)
	endif

	// find and check child index's
	do
		if(numchildren>1)
			// get highlevel key index
			newchildindex = getJSONkeyindex(stringfromlist(0,children,","),t_tokentext,offset=offset)
			children = removelistitem(0,children,",")
			numchildren -= 1
			if(childindex >= newchildindex)
				print "[ERROR]: children keys are not in correct order!"
				return ""
			endif
			childindex = newchildindex
			offset = childindex
		elseif(numchildren==1)
			offset = childindex
			newchildindex = getJSONkeyindex(stringfromlist(0,children),t_tokentext,offset=offset)
			if(w_tokensize[newchildindex+1]>0)
				childindex = newchildindex+1
			else
				childindex = newchildindex
			endif
			break
		else
			break
		endif
	while(numchildren>0)

	// given the lowest level child index, find all values belonging to this key
	for(i=0;i<numpnts(w_tokenparent);i+=1)
		if(w_tokenparent[i] == childindex)
			valuelist = addlistitem(t_tokentext[i],valuelist,",",inf)
		endif
	endfor

	// returns a comma seperated list of values
	return valuelist
end

function/s getJSONkeys(JSONstr)
	// returns a list of all keys, seperated by comma
	// list will include a new entry per key
	// the keys will be parsed along with its parents, e.g. "key1,key1:child1,key1:child1:child11"
	string JSONstr
	string keylist="", currentparentkeylist=""
	variable i=0, j=0, k=0, topparentkeyindex=0, parentkeyindex=0

	JSONSimple JSONstr
	wave/t t_tokentext
	wave w_tokensize, w_tokenparent, w_tokentype

	for(i=1;i<numpnts(w_tokensize);i+=1) // the first is not really a key, so start af i=1
		if(w_tokensize[i]==1 && w_tokentype[i]==3) // this is a key
			if(w_tokenparent[i]==0)
				if(itemsinlist(currentparentkeylist,":")>1)
					keylist = addlistitem(currentparentkeylist,keylist,",",inf)
				endif
				currentparentkeylist = ""
				keylist = addlistitem(t_tokentext[i],keylist,",",inf)
				currentparentkeylist = addlistitem(t_tokentext[i],currentparentkeylist,":",inf)
				if(w_tokentype[i+1]==1) // next "object" is a JSON object, so child keys sees this object as parent.
					j = i+1
				else
					j=i
				endif
				topparentkeyindex = j
				parentkeyindex = topparentkeyindex
			elseif(w_tokenparent[i]==topparentkeyindex) // this is a "first" child
				if(itemsinlist(currentparentkeylist,":")>1)
					keylist = addlistitem(currentparentkeylist,keylist,",",inf)
					currentparentkeylist = stringfromlist(0,currentparentkeylist,":")
				endif
				currentparentkeylist = addlistitem(t_tokentext[i],currentparentkeylist,":",inf)
				if(w_tokentype[i+1]==1) // next "object" is a JSON object, so child keys sees this object as parent.
					j = i+1
				else
					j=i
				endif
				parentkeyindex = j
			elseif(w_tokenparent[i]==parentkeyindex)
				if(itemsinlist(currentparentkeylist,":")>1)
					keylist = addlistitem(currentparentkeylist,keylist,",",inf)
				endif
				currentparentkeylist = addlistitem(t_tokentext[i],currentparentkeylist,":",inf)
				if(w_tokentype[i+1]==1) // next "object" is a JSON object, so child keys sees this object as parent.
					j = i+1
				else
					j=i
				endif
				parentkeyindex = j
			endif
		endif
	endfor

	if(itemsinlist(currentparentkeylist,":")>1) // if the last key is a child, add it to the keylist
		keylist = addlistitem(currentparentkeylist,keylist,",",inf)
	endif

	return keylist
end

function/s getJSONvalue(JSONstr,key,[parents])
	// will return the value assosiated with the passed key
	// parents should be a sting list "parent1,parent2", where parent2 is down stream from parent1
	string JSONstr, key, parents
	string parentindexlist="", JSONvalues=""
	variable i=0, j=0, numparents, offset, index

	if(paramisdefault(parents))
		parents = ""
	endif

	JSONSimple JSONstr
	wave/t t_tokentext
	wave w_tokensize, w_tokenparent, w_tokentype

	numparents = itemsinlist(parents,",")
	if(numparents>0)
		for(i=0;i<numparents;i+=1)
			parentindexlist = addlistitem(num2str(getJSONkeyindex(stringfromlist(i,parents,","),t_tokentext)),parentindexlist,",",inf)
		endfor
		offset = str2num(stringfromlist(itemsinlist(parentindexlist)-1,parentindexlist,","))
	else
		offset = 0
	endif

	index = getJSONkeyindex(key,t_tokentext,offset=offset)
	for(i=offset;i<numpnts(w_tokenparent);i+=1) // no need to check before i=offset
		if(w_tokenparent[i]==index)
			if(w_tokentype[i]==3)
				return "\""+t_tokentext[i]+"\""
			else
				return t_tokentext[i]
			endif
		endif
	endfor
	return ""
end

function getJSONkeyindex(key,tokenwave,[offset])
	string key
	wave/t tokenwave
	variable offset
	variable i=0

	if(paramisdefault(offset))
		offset = 0
	endif

	for(i=offset;i<numpnts(tokenwave);i+=1)
		if(cmpstr(key,tokenwave[i])==0)
			return i
		endif
	endfor

	printf "[ERROR]: key (%s) not found!\r", key
	return -1
end

///////////
/// INI ///
///////////