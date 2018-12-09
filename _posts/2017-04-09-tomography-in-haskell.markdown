---
layout: post
title:  "Tomography in Haskell"
imgdir:  "tomographyinhaskell"
date:   2017-04-10 21:20:00 +0100
excerpt: "Simulated computed tomography with Haskell and Repa library"
tags: haskell algorithms
---
# Intro
My task was to make an computer tomography in haskell. First, some explenations how tomographs works:

{% include image.html image='ball.svg' caption='Our object to scan' %}

Yeah, now we will put some Xrays through it. What we will see distribution of material blocking Xrays in our object (you can think about it as a "density" for simplicity, but it's not that). For example:

{% include image.html image='ball_projection.svg' caption='first projection' %}

Here we've got a projection of our ball in angle of 0 radians. We must iterate that method from 0 to &pi; radians. Because our object is a ball, and it's in the center, all our projections will look like this. Whole table of projections is called a "sinogram". With that we can recreate the inside of our patient without actually cut him! Let's look how our reconstruction will looks like:

{% include image.html image='ball_reconstruct.svg' %}

From two projections we can figure out that our object looks something like a square and is placed in center of our image. Imagine having 500 projections! Making this projections is done by Radon Transform. Unfortunately this will not works so good. Thats because pixels in center are in "focus", things outside the center will tend to be blury. Look at the explenation:

{% include image.html image='explenation.svg' %}

That will be the "classic tomography". But that is the relict of the past. I will focus on "computed tomography". Using some filters we will try to fix that. In this case I use the *ramp* filter. How it works?

{% include image.html image='process.svg' %}

First, we take our projection and by fft we move it to frequency domain. Then we multiply that by our filter. It makes the lower frequencies less significant in our analysis and also removes the highest. Then, thankfully to inverse FFT we go back to our "time" domain. You can do it only in time domain by convolution, but doing it with fft is much faster (but harder, and in real world tomography as far as I now convolution is used).

# Code

Let's jump into implementation. I use here mainly 2 libraries: `Data.Array.Repa` for all array work and `Codec.Picture` for loading and saving images.

## Load the image

{% highlight haskell linenos=table %}
rgbToGrey :: PixelRGB8 -> Double
rgbToGrey (PixelRGB8 r g b) =
  let rgb = P.zipWith (*) [0.2126, 0.7152, 0.0722] $ P.map (fromIntegral) [r, g, b] 
  in fromInteger . round . sum $ rgb :: Double

imageToArray :: String -> IO (Int, Int, Array U DIM2 Double)
imageToArray fname = do
    Right imgRGB <- readImage fname
    let (imgGray@(Image w h _)) = convertRGB8 imgRGB 
        arr = fromFunction (Z :. w :. h) (\(Z :. x :. y) -> rgbToGrey $ pixelAt imgGray x y)
    img <- computeUnboxedP arr
    return (w, h, img)
{% endhighlight %}

Yeah, it should be pretty self explanatory. Load image, turn it to grayscale and return the width, height and array with image itself.

{% include image.html image='shep.png' caption='test object' %}

## Create sinogram
After that we have to create our sinogram. I wrote these functions:

{% highlight haskell linenos=table %}

getY a p r x = (x, round ((p - (fromIntegral (x - r) * (cos a))) / (sin a)) + r)
getX a p r y = (round ((p - (fromIntegral (y - r) * (sin a))) / (cos a)) + r, y)

filterCoords r (x, y) = ((fromIntegral x - r)**2 + (fromIntegral y - r)**2) < r**2

getLineAvg :: Double -> Double -> Int -> (Double -> Double -> Int -> Int -> (Int, Int)) -> Array U DIM2 Double -> Double
getLineAvg a p w getCoord img =
    let pixelList = P.map (getCoord a p (div w 2)) [0..w-1]
        r = (fromIntegral w) / 2
        pixelList' = filter (filterCoords r) pixelList
        len = length pixelList'
        ret = (sum $ P.map (\(x, y) -> img ! (Z :. x :. y)) pixelList') / fromIntegral len
    in if isNaN ret then 0 else ret

getDetectorValue :: Double -> Double -> Int -> Array U DIM2 Double -> Double
getDetectorValue a p w img
    | a < pi/4 || a > (3 * pi)/4 = getLineAvg a p w getX img
    | otherwise = getLineAvg a p w getY img
{% endhighlight %}

I operate here on normal form of the equation of a line: ` y * sin a + x * cos a = p' so:
+ `a` - is an angle
+ `p` - is distance from (0, 0) - it's the center of the image
+ `w` - the width of the image

I map getDetectorValue across all angles I want to scan my object, and then map it with distance of detector line from center of image. If think that's interesting how easy is to write in Haskell functions with pattern matching. 

After that it's time to normalize our array.

{% highlight haskell linenos=table %}
normalize :: Monad m => Array U DIM2 Double -> m (Array D DIM2 Double)
normalize arr = do
    minn <- foldAllP min 1 arr
    let arrmin = R.map (+ (-minn)) arr
    maxx <- foldAllP max 0 arrmin
    return $ R.map (/maxx) arrmin
{% endhighlight %}

Fold's in haskell are like reduce. Give it an array and function by which it will combine all elements.

## Applying filter

Now we will apply filter to our sinogram. We do it row by row. Here is our implementation of *ramp* filter:

{% highlight haskell linenos=table %}
myfilter tresh v
    | v < tresh = fromIntegral v * 0.6
    | otherwise = 0

rowFilter :: Monad m => Array D DIM1 Double -> m (Array D DIM1 Double)
rowFilter row = do
    rowComplex <- computeP $ R.map (\x -> x :+ 0 ) row
    let fftF = fft $ rowComplex
        (Z :. w) = extent fftF
        barier = round (fromIntegral w/2)
        filtered = fromListUnboxed (Z :. w) $ (P.map (myfilter barier) [1..w])
        fftFilt = R.zipWith (*) fftF filtered
    ifftF <- fmap ifft $ computeP fftFilt
    return $ R.map realPart ifftF
{% endhighlight %}

First we make our array an array of complex numbers. Then perform FFT and multiply it by our filter. After performing IFFT we are done. Unfortunately 'Repa' library doesn't provide function to map through certain dimensions of array (at least I cannot find it), so I have to write my own.

{% highlight haskell linenos=table %}
mapRows :: Monad m => (Array D DIM1 Double -> m (Array D DIM1 Double)) -> Array D DIM2 Double -> m (Array U DIM2 Double)
mapRows func array = do
    let (Z :. w :. h) = extent array
    rows <- mapM (\num -> do
        let row = getRow array num
        func row) [0,1..(w-1)]
    let hugeRow = toList $ foldr1 append rows
    return $ fromListUnboxed (Z :. w :. h) hugeRow
{% endhighlight %}

After that we've got filtered singoram.

{% include image.html image='sinogram.png' caption='nofilter / filter' %}

## Reconstruct
Last thing what we've got to do is to perform Inverse Radon Transform.

{% highlight haskell linenos=table %}
reconstruct :: Array D DIM2 Double -> Double -> Int -> IO ()
reconstruct img p orgW = do
    let (Z :. w :. h) = extent img
        angleStep = pi / fromIntegral h
        anglesList = takeWhile (<pi) [a * angleStep | a <- [0..]]
        orgWNum = fromIntegral orgW

        listOfIndicies (x, y) = let
            list = P.map (\a -> round $ (x * sin a + y * cos a)/p + orgWNum/2) anglesList
            list_zip = zip list [0..(h-1)]
            in [(a,b) | (a,b) <- list_zip, a >= 0, a < w]

        render (x, y) = let
            list = listOfIndicies (x, y)
            pixelList = P.map (\(p, h) -> img ! (Z :. p :. h)) list
            pixelSum = sum pixelList
            avg = pixelSum / (fromIntegral $ length pixelList)
            in if avg > 0 then avg else 0

    let imageIndicies = [orgWNum/(-2)..orgWNum/2-1]
        img' = fromListUnboxed (Z :. orgW :. orgW) (P.map render [(a,b) | a <- imageIndicies , b <- imageIndicies])
    img <- normalize img'
    writePng "res/reconstruct.png" $ generateImage (\x y -> dToPx (img ! (Z :. x :. y))) orgW orgW
{% endhighlight %}


That's it! `listOfIndicies (x, y)` returns an array with indicies of sinogram that we should consider in calulating the value of `(x, y)` in our reconstructed image. `render (x, y)` returns the value of pixel `(x, y)` in this image. Let's look at the results:

{% include image.html image='all.png' caption='original and after 10, 50, 100 scans' %}

Pretty good, but it's not the limit of this method. Compared to Python solutions I saw, Haskell implementation is pretty fast! Whole repository you can find [on github](https://github.com/maciejspychala/haskell_tomography). That's all, thanks!
