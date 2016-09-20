module DAT
export registerDATFunction, mapCube, getInAxes, getOutAxes, findAxis
importall ..Cubes
importall ..CubeAPI
importall ..CubeAPI.CachedArrays
importall ..CABLABTools
importall ..Cubes.TempCubes
import ...CABLAB
import ...CABLAB.workdir
using Base.Dates
#import DataArrays.DataArray
#import DataArrays.isna
global const debugDAT=false
macro debug_print(e)
  debugDAT && return(:(println($e)))
  :()
end
#Clear Temp Folder when loading
#myid()==1 && isdir(joinpath(workdir[1],"tmp")) && rm(joinpath(workdir[1],"tmp"),recursive=true)

"""
Configuration object of a DAT process. This holds all necessary information to perform the calculations
It contains the following fields:

- `incubes::Vector{AbstractCubeData}` The input data cubes
- `outcube::AbstractCubeData` The output data cube
- `indims::Vector{Tuple}` Tuples of input axis types
- `outdims::Tuple` Tuple of output axis types
- `axlists::Vector{Vector{CubeAxis}}` Axes of the input data cubes
- inAxes::Vector{Vector{CubeAxis}}
- outAxes::Vector{CubeAxis}
- LoopAxes::Vector{CubeAxis}
- axlistOut::Vector{CubeAxis}
- ispar::Bool
- isMem::Vector{Bool}
- inCubesH
- outCubeH

"""
type DATConfig{N}
  NIN           :: Int
  incubes       :: Vector
  outcube       :: AbstractCubeData
  axlists       :: Vector #Of vectors
  inAxes        :: Vector #Of vectors
  broadcastAxes :: Vector #Of Vectors
  outAxes       :: Vector
  LoopAxes      :: Vector
  axlistOut     :: Vector
  ispar         :: Bool
  isMem         :: Vector{Bool}
  inCacheSizes  :: Vector #of vectors
  loopCacheSize :: Vector{Int}
  inCubesH
  outCubeH
  max_cache
  outfolder
  sfu
  inmissing     :: Tuple
  outmissing    :: Symbol
  no_ocean      :: Int
  addargs
end
function DATConfig(incubes::Tuple,inAxes,outAxes,outtype,max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,addargs)
  DATConfig{length(incubes)}(length(incubes),AbstractCubeData[c for c in incubes],EmptyCube{outtype}(),Vector{CubeAxis}[],inAxes,
  Vector{Int}[],CubeAxis[a for a in outAxes],CubeAxis[],CubeAxis[],nprocs()>1,Bool[isa(x,AbstractCubeMem) for x in incubes],
  Vector{Int}[],Int[],[],[],max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,addargs)
end

"""
Object to pass to InnerLoop, this condenses the most important information about the calculation into a type so that
specific code can be generated by the @generated function
"""
immutable InnerObj{NIN,T1,T2,T3,MIN,MOUT,OC} end
function InnerObj(dc::DATConfig)
  T1=totuple(map(length,dc.inAxes))
  T2=length(dc.outAxes)
  T3=totuple(map(totuple,dc.broadcastAxes))
  MIN=dc.inmissing
  MOUT=dc.outmissing
  OC=dc.no_ocean
  InnerObj{dc.NIN,T1,T2,T3,MIN,MOUT,OC}()
end

immutable DATFunction
  indims
  outdims
  args
  inmissing
  outmissing
  no_ocean
end
const regDict=Dict{UTF8String,DATFunction}()

getOuttype(sfu,cdata)=isa(cdata,AbstractCubeData) ? eltype(cdata) : eltype(cdata[1])
getInAxes(sfu,cdata)=error("No input Axes provided")
getOutAxes(sfu,cdata)=error("No output Axes provided")
function getInAxes(sfu::DATFunction,cdata::Tuple)
  inAxes=Vector{CubeAxis}[]
  for (dat,dim) in zip(cdata,sfu.indims)
    ii=collect(map(a->findAxis(a,axes(dat)),dim))
    if length(ii) > 0
      push!(inAxes,axes(dat)[ii])
    else
      push!(inAxes,CubeAxis[])
    end
  end
  inAxes
end
getOutAxes(sfu::DATFunction,cdata,pargs)=map(t->getOutAxes(cdata,t,pargs),sfu.outdims)
function getOutAxes(cdata::Tuple,t::DataType,pargs)
  for da in cdata
    ii = findAxis(t,axes(da))
    ii>0 && return axes(da)[ii]
  end
end
getOutAxes(cdata::Tuple,t::Function,pargs)=t(cdata,pargs)


mapCube(fu::Function,cdata::AbstractCubeData,addargs...;kwargs...)=mapCube(fu,(cdata,),addargs...;kwargs...)

"""
    mapCube(fun, cube)

Map a given function `fun` over slices of the data cube `cube`. 
"""
function mapCube(fu::Function,cdata::Tuple,addargs...;max_cache=1e7,outfolder=joinpath(workdir[1],string(tempname()[2:end],fu)),
  sfu=split(string(fu),".")[end],fuObj=get(regDict,sfu,sfu),outtype=getOuttype(fuObj,cdata),inAxes=getInAxes(fuObj,cdata),outAxes=getOutAxes(fuObj,cdata,addargs),
  inmissing=isa(fuObj,DATFunction) ? fuObj.inmissing : ntuple(i->:mask,length(cdata)),outmissing=isa(fuObj,DATFunction) ? fuObj.outmissing : :mask, no_ocean=isa(fuObj,DATFunction) ? fuObj.no_ocean : 0)
  @debug_print "In map function"
  isdir(outfolder) || mkpath(outfolder)
  @debug_print "Generating DATConfig"
  dc=DATConfig(cdata,inAxes,outAxes,outtype,max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,addargs)
  analyseaddargs(fuObj,dc)
  @debug_print "Reordering Cubes"
  reOrderInCubes(dc)
  @debug_print "Analysing Axes"
  analyzeAxes(dc)
  @debug_print "Calculating Cache Sizes"
  getCacheSizes(dc)
  @debug_print "Generating Output Cube"
  generateOutCube(dc)
  @debug_print "Generating cube handles"
  getCubeHandles(dc)
  @debug_print "Running main Loop"
  runLoop(dc)

  return dc.outcube

end

function enterDebug(fu::Function,cdata::Tuple,addargs...;max_cache=1e7,outfolder=joinpath(workdir[1],string(tempname()[2:end],fu)),
  sfu=split(string(fu),".")[end],fuObj=get(regDict,sfu,sfu),outtype=getOuttype(fuObj,cdata),inAxes=getInAxes(fuObj,cdata),outAxes=getOutAxes(fuObj,cdata,addargs),
  inmissing=isa(fuObj,DATFunction) ? fuObj.inmissing : ntuple(i->:mask,length(cdata)),outmissing=isa(fuObj,DATFunction) ? fuObj.outmissing : :mask, no_ocean=isa(fuObj,DATFunction) ? fuObj.no_ocean : 0)
    isdir(outfolder) || mkpath(outfolder)
    return DATConfig(cdata,inAxes,outAxes,outtype,max_cache,outfolder,sfu,inmissing,outmissing,no_ocean,addargs),fuObj
end

function analyseaddargs(sfu::DATFunction,dc)
    dc.addargs=isa(sfu.args,Function) ? sfu.args(dc.incubes,dc.addargs) : dc.addargs
end
analyseaddargs(sfu::AbstractString,dc)=nothing

function mustReorder(cdata,inAxes)
  reorder=false
  axlist=axes(cdata)
  for (i,fi) in enumerate(inAxes)
    axlist[i]==fi || return true
  end
  return false
end

function reOrderInCubes(dc::DATConfig)
  cdata=dc.incubes
  inAxes=dc.inAxes
  for i in 1:length(cdata)
    if mustReorder(cdata[i],inAxes[i])
      perm=getFrontPerm(cdata[i],inAxes[i])
      cdata[i]=permutedims(cdata[i],perm)
    end
    push!(dc.axlists,axes(cdata[i]))
  end
end

function runLoop(dc::DATConfig)
  if dc.ispar
    allRanges=distributeLoopRanges(dc.outcube.block_size.I[(end-length(dc.LoopAxes)+1):end],map(length,dc.LoopAxes))
    pmap(r->CABLAB.DAT.innerLoop(Val{Symbol(Main.PMDATMODULE.dc.sfu)},CABLAB.CABLABTools.totuple(Main.PMDATMODULE.dc.inCubesH),
      Main.PMDATMODULE.dc.outCubeH[1],CABLAB.DAT.InnerObj(Main.PMDATMODULE.dc),r,Main.PMDATMODULE.dc.addargs),allRanges)
    isa(dc.outcube,TempCube) && @everywhereelsem CachedArrays.sync(dc.outCubeH[1])
  else
    innerLoop(Val{Symbol(dc.sfu)},totuple(dc.inCubesH),dc.outCubeH[1],InnerObj(dc),totuple(map(length,dc.LoopAxes)),dc.addargs)
    isa(dc.outCubeH[1],CachedArray) && CachedArrays.sync(dc.outCubeH[1])
  end
  dc.outcube
end

function generateOutCube(dc::DATConfig)
  T=eltype(dc.outcube)
  outsize=sizeof(T)*(length(dc.axlistOut)>0 ? prod(map(length,dc.axlistOut)) : 1)
  if outsize>dc.max_cache || dc.ispar
    dc.outcube=TempCube(dc.axlistOut,CartesianIndex(totuple([map(length,dc.outAxes);dc.loopCacheSize])),folder=dc.outfolder,T=T)
  else
    newsize=map(length,dc.axlistOut)
    dc.outcube = Cubes.CubeMem{T,length(newsize)}(dc.axlistOut, zeros(T,newsize...),zeros(UInt8,newsize...))
  end
end

dcg=nothing
function getCubeHandles(dc::DATConfig)
  if dc.ispar
    global dcg=dc
    try
      passobj(1, workers(), [:dcg],from_mod=CABLAB.DAT,to_mod=Main.PMDATMODULE)
    end
    @everywhereelsem begin
      dc=Main.PMDATMODULE.dcg
      tc=openTempCube(dc.outfolder)
      push!(dc.outCubeH,CachedArray(tc,1,tc.block_size,MaskedCacheBlock{eltype(tc),length(tc.block_size.I)}))
      for icube=1:dc.NIN
        if dc.isMem[icube]
          push!(dc.inCubesH,dc.incubes[icube])
        else
          push!(dc.inCubesH,CachedArray(dc.incubes[icube],1,CartesianIndex(totuple(dc.inCacheSizes[icube])),MaskedCacheBlock{eltype(dc.incubes[icube]),length(dc.axlists[icube])}))
        end
      end
    end
  else
    # For one-processor operations
    for icube=1:dc.NIN
      if dc.isMem[icube]
        push!(dc.inCubesH,dc.incubes[icube])
      else
        push!(dc.inCubesH,CachedArray(dc.incubes[icube],1,CartesianIndex(totuple(dc.inCacheSizes[icube])),MaskedCacheBlock{eltype(dc.incubes[icube]),length(dc.axlists[icube])}))
      end
    end
    if isa(dc.outcube,TempCube)
      push!(dc.outCubeH,CachedArray(dc.outcube,1,dc.outcube.block_size,MaskedCacheBlock{eltype(dc.outcube),length(dc.axlistOut)}))
    else
      push!(dc.outCubeH,dc.outcube)
    end
  end
end

function init_DATworkers()
  freshworkermodule()
end

function analyzeAxes(dc::DATConfig)
  #First check if one of the axes is a concrete type
  for icube=1:dc.NIN
    for a in dc.axlists[icube]
      in(a,dc.inAxes[icube]) || in(a,dc.LoopAxes) || push!(dc.LoopAxes,a)
    end
  end
  #Try to construct outdims
  outnotfound=find([!isdefined(dc.outAxes,ii) for ii in eachindex(dc.outAxes)])
  for ii in outnotfound
    dc.outAxes[ii]=dc.outdims[ii]()
  end
  length(dc.LoopAxes)==length(unique(map(typeof,dc.LoopAxes))) || error("Make sure that cube axes of different cubes match")
  dc.axlistOut=CubeAxis[dc.outAxes;dc.LoopAxes]
  for icube=1:dc.NIN
    push!(dc.broadcastAxes,Int[])
    for iLoopAx=1:length(dc.LoopAxes)
      !in(typeof(dc.LoopAxes[iLoopAx]),map(typeof,dc.axlists[icube])) && push!(dc.broadcastAxes[icube],iLoopAx)
    end
  end
  return dc
end

function getCacheSizes(dc::DATConfig)

  if all(dc.isMem)
    dc.inCacheSizes=[Int[] for i=1:dc.NIN]
    dc.loopCacheSize=Int[length(x) for x in dc.LoopAxes]
    return dc
  end
  inAxlengths      = [Int[length(dc.inAxes[i][j]) for j=1:length(dc.inAxes[i])] for i=1:length(dc.inAxes)]
  inblocksizes     = map((x,T)->prod(x)*sizeof(eltype(T)),inAxlengths,dc.incubes)
  inblocksize,imax = findmax(inblocksizes)
  outblocksize     = length(dc.outAxes)>0 ? sizeof(eltype(dc.outcube))*prod(map(length,dc.outAxes)) : 1
  loopCacheSize    = getLoopCacheSize(max(inblocksize,outblocksize),dc.LoopAxes,dc.max_cache)
  @debug_print "Choosing Cache Size of $loopCacheSize"
  for icube=1:dc.NIN
    if dc.isMem[icube]
      push!(dc.inCacheSizes,Int[])
    else
      push!(dc.inCacheSizes,map(length,dc.inAxes[icube]))
      for iLoopAx=1:length(dc.LoopAxes)
        in(typeof(dc.LoopAxes[iLoopAx]),map(typeof,dc.axlists[icube])) && push!(dc.inCacheSizes[icube],loopCacheSize[iLoopAx])
      end
    end
  end
  dc.loopCacheSize=loopCacheSize
  return dc
end

"Calculate optimal Cache size to DAT operation"
function getLoopCacheSize(preblocksize,LoopAxes,max_cache)
  totcachesize=max_cache

  incfac=totcachesize/preblocksize
  incfac<1 && error("Not enough memory, please increase availabale cache size")
  loopCacheSize = ones(Int,length(LoopAxes))
  for iLoopAx=1:length(LoopAxes)
    s=length(LoopAxes[iLoopAx])
    if s<incfac
      loopCacheSize[iLoopAx]=s
      incfac=incfac/s
      continue
    else
      ii=floor(Int,incfac)
      while ii>1 && rem(s,ii)!=0
        ii=ii-1
      end
      loopCacheSize[iLoopAx]=ii
      break
    end
  end
  return loopCacheSize
  j=1
  CacheInSize=Int[]
  for a in axlist
    if typeof(a) in indims
      push!(CacheInSize,length(a))
    else
      push!(CacheInSize,loopCacheSize[j])
      j=j+1
    end
  end
  @assert j==length(loopCacheSize)+1
  CacheOutSize = [map(length,outAxes);loopCacheSize]
  return CacheInSize, CacheOutSize
end

using Base.Cartesian
@generated function distributeLoopRanges{N}(block_size::NTuple{N,Int},loopR::Vector)
    quote
        @assert length(loopR)==N
        nsplit=Int[div(l,b) for (l,b) in zip(loopR,block_size)]
        baseR=UnitRange{Int}[1:b for b in block_size]
        a=Array(NTuple{$N,UnitRange{Int}},nsplit...)
        @nloops $N i a begin
            rr=@ntuple $N d->baseR[d]+(i_d-1)*block_size[d]
            @nref($N,a,i)=rr
        end
        a=reshape(a,length(a))
    end
end

using Base.Cartesian
@generated function innerLoop{fT,T1,T2,T3,T4,NIN,M1,M2,OC}(::Type{Val{fT}},xin,xout,::InnerObj{NIN,T1,T2,T4,M1,M2,OC},loopRanges::T3,addargs)
  NinCol      = T1
  NoutCol     = T2
  broadcastvars = T4
  inmissing     = M1
  outmissing    = M2
  Nloopvars   = length(T3.parameters)
  loopRangesE = Expr(:block)
  subIn=[NinCol[i] > 0 ? Expr(:call,:(getSubRange2),:(xin[$i]),fill(:(:),NinCol[i])...) : Expr(:call,:(CABLAB.CubeAPI.CachedArrays.getSingVal),:(xin[$i])) for i=1:NIN]
  subOut=Expr(:call,:(getSubRange2),:xout,fill(:(:),NoutCol)...)
  printex=Expr(:call,:println,:outstream)
  for i=Nloopvars:-1:1
    isym=Symbol("i_$(i)")
    push!(printex.args,string(isym),"=",isym," ")
  end
  for i=1:Nloopvars
    isym=Symbol("i_$(i)")
    for j=1:NIN
      in(i,broadcastvars[j]) || push!(subIn[j].args,isym)
    end
    push!(subOut.args,isym)
    if T3.parameters[i]==UnitRange{Int}
      unshift!(loopRangesE.args,:($isym=loopRanges[$i]))
    elseif T3.parameters[i]==Int
      unshift!(loopRangesE.args,:($isym=1:loopRanges[$i]))
    else
      error("Wrong Range argument")
    end
  end
  push!(subOut.args,Expr(:kw,:write,true))
  loopBody=quote
    aout,mout=$subOut
  end
  if outmissing==:mask
    callargs=Any[:(Main.$(fT)),:aout,:mout]
  elseif outmissing==:nan
    callargs=Any[:(Main.$(fT)),:aout]
#  elseif outmissing==:dataarray
#    callargs=Any[:(Main.$(fT)),:aout]
#    push!(loopBody.args,:(aout=toDataArray(aout,mout)))
  end
  for (i,s) in enumerate(subIn)
    ains=symbol("ain_$i");mins=symbol("min_$i")
    push!(loopBody.args,:(($(ains),$(mins))=$s))
    push!(callargs,ains)
    if inmissing[i]==:mask
      push!(callargs,mins)
    elseif inmissing[i]==:nan
      push!(loopBody.args,:(fillNaNs($(ains),$(mins))))
#    elseif inmissing[i]==:dataarray
#      push!(loopBody.args,:($(ains)=toDataArray($(ains),$(mins))))
    end
  end
  if OC>0
    ocex=quote
      if ($(symbol(string("min_",OC)))[1] & OCEAN) == OCEAN
          mout[:]=OCEAN
          continue
      end
    end
    push!(loopBody.args,ocex)
  end
  push!(callargs,Expr(:...,:addargs))
  push!(loopBody.args,Expr(:call,callargs...))
  if outmissing==:nan
    push!(loopBody.args, :(fillNanMask(aout,mout)))
#  elseif outmissing==:dataarray
#    push!(loopBody.args,:(fillDataArrayMask(aout,mout)))
  end
  loopEx = length(loopRangesE.args)==0 ? loopBody : Expr(:for,loopRangesE,loopBody)
  @debug_print loopEx
  return loopEx
end

"This function sets the values of x to NaN if the mask is missing"
function fillNaNs(x::AbstractArray,m::AbstractArray{UInt8})
  for i in eachindex(x)
    (m[i] & 0x01)==0x01 && (x[i]=NaN)
  end
  x
end
fillNaNs(x,::Void)=nothing
"Sets the mask to missing if values are NaN"
function fillNanMask(x,m)
  for i in eachindex(x)
    m[i]=isnan(x[i]) ? 0x01 : 0x00
  end
end
#"Converts data and Mask to a DataArray"
#toDataArray(x,m)=DataArray(pointer_to_array(pointer(x),size(x)),reinterpret(Bool,copy(m)))
#fillDataArrayMask(x,m)=for i in eachindex(x) m[i]=isna(x[i]) ? 0x01 : 0x00 end

function registerDATFunction(f, ::Tuple{}, dimsout::Tuple, addargs;inmissing=(:mask,),outmissing=:mask,no_ocean=0)
  fname=utf8(split(string(f),".")[end])
  regDict[fname]=DATFunction((),dimsout,addargs,inmissing,outmissing,no_ocean)
end

function registerDATFunction(f,dimsin::Tuple{Vararg{DataType}},dimsout::Tuple,addargs;inmissing=ntuple(i->:mask,length(dimsin)),outmissing=:mask,no_ocean=0)
    fname=utf8(split(string(f),".")[end])
    regDict[fname]=DATFunction((dimsin,),dimsout,addargs,inmissing,outmissing,no_ocean)
end

function registerDATFunction(f,dimsin::Tuple{Vararg{Tuple{Vararg{DataType}}}},dimsout::Tuple,addargs;inmissing=ntuple(i->:mask,length(dimsin)),outmissing=:mask,no_ocean=0)
    fname=utf8(split(string(f),".")[end])
    regDict[fname]=DATFunction(dimsin,dimsout,addargs,inmissing,outmissing,no_ocean)
end
registerDATFunction(f,dimsin,dimsout;inmissing=ntuple(i->:mask,length(dimsin)),outmissing=:mask,no_ocean=0)=registerDATFunction(f,dimsin,dimsout,(),inmissing=inmissing,outmissing=outmissing,no_ocean=no_ocean)
registerDATFunction(f,dimsin;inmissing=ntuple(i->:mask,length(dimsin)),outmissing=:mask,no_ocean=0)=registerDATFunction(f,dimsin,(),inmissing=inmissing,outmissing=outmissing,no_ocean=no_ocean)

"Find a certain axis type in a vector of Cube axes and returns the index"
function findAxis{T<:CubeAxis}(a::Type{T},v)
    for i=1:length(v)
        isa(v[i],a) && return i
    end
    return 0
end

function findAxis(matchstr::AbstractString,axlist)
    ism=map(i->startswith(lowercase(split(string(typeof(i)),".")[end]),lowercase(matchstr)),axlist)
  sism=sum(ism)
  sism==0 && error("No axis found matching string $matchstr")
  sism>1 && error("Multiple axes found matching string $matchstr")
  i=findfirst(ism)
end


function getAxis{T<:CubeAxis}(a::Type{T},v)
  for i=1:length(v)
      isa(v[i],a) && return a
  end
  return 0
end


"Calculate an axis permutation that brings the wanted dimensions to the front"
function getFrontPerm{T}(dc::AbstractCubeData{T},dims)
  ax=axes(dc)
  N=length(ax)
  perm=Int[i for i=1:length(ax)];
  iold=Int[]
  for i=1:length(dims) push!(iold,findin(ax,[dims[i];])[1]) end
  iold2=sort(iold,rev=true)
  for i=1:length(iold) splice!(perm,iold2[i]) end
  perm=Int[iold;perm]
  return ntuple(i->perm[i],N)
end

end
