# The purpose of this section is to do a collection of small 
# convinient pieces of code on how to do simple things.

# !!! question

# ## extract the axes names from a Cube?

using YAXArrays
c = YAXArray(rand(10,10,5))

caxes(c)

# !!! question

# ## concatenate cubes?

# It is possible to concatenate several cubes that shared the same dimensions using the [`concatenatecubes`]@ref function.

# let's create two dummy cubes

using YAXArrays

axlist = [
    RangeAxis("time", range(1, 20, length=20)),
    RangeAxis("lon", range(1, 10, length=10)),
    RangeAxis("lat", range(1, 5, length=15))]

data1 = rand(20, 10, 15)
ds1 = YAXArray(axlist, data1)

data2 = rand(20, 10, 15)
ds2 = YAXArray(axlist, data2)

# Now we can concatenate ```ds1``` and ```ds2``` cubes:

dsfinal = concatenatecubes([ds1, ds2], 
    CategoricalAxis("Variables", ["var1", "var2"]))

dsfinal