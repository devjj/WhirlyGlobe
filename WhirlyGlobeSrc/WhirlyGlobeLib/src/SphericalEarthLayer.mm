/*
 *  SphericalEarth.mm
 *  WhirlyGlobeLib
 *
 *  Created by Steve Gifford on 1/11/11.
 *  Copyright 2011-2012 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import <UIKit/UIKit.h>
#import "SphericalEarthLayer.h"
#import "UIImage+Stuff.h"
#import "GlobeMath.h"

using namespace WhirlyKit;
using namespace WhirlyGlobe;

@implementation WhirlyGlobeSphericalEarthLayer

@synthesize fade;
@synthesize drawPriority;

- (id)initWithTexGroup:(WhirlyKitTextureGroup *)inTexGroup
{
    return [self initWithTexGroup:inTexGroup cacheName:nil];
}

- (id)initWithTexGroup:(WhirlyKitTextureGroup *)inTexGroup cacheName:(NSString *)inCacheName;
{
	if ((self = [super init]))
	{
		texGroup = inTexGroup;
		xDim = texGroup.numX;
		yDim = texGroup.numY;
        savingToCache = false;
        cacheName = inCacheName;
        cacheWriter = NULL;
        fade = 0.0;
        drawPriority = 0;
	}
	
	return self;
}

- (void)clear
{
    texIDs.clear();
    drawIDs.clear();
    
    scene = NULL;
}

- (void)dealloc
{
    [self clear];

    if (cacheWriter)
        delete cacheWriter;
    cacheWriter = NULL;
}

- (void)saveToCacheName:(NSString *)inCacheName
{
    savingToCache = true;
    cacheName = inCacheName;
}

// Set up the next chunk to build and schedule it
- (void)startWithThread:(WhirlyKitLayerThread *)inLayerThread scene:(Scene *)inScene
{
    layerThread = inLayerThread;	
    scene = (WhirlyGlobe::GlobeScene *)inScene;
	chunkX = chunkY = 0;
	[self performSelector:@selector(startProcess:) withObject:nil];
}

- (void)shutdown
{
    std::vector<ChangeRequest *> changeRequests;
    
    for (unsigned int ii=0;ii<drawIDs.size();ii++)
        changeRequests.push_back(new RemDrawableReq(drawIDs[ii]));
    for (unsigned int ii=0;ii<texIDs.size();ii++)
        changeRequests.push_back(new RemTextureReq(texIDs[ii]));
    
    scene->addChangeRequests(changeRequests);
    
    [self clear];
}

using namespace WhirlyGlobe;

// Load from a pregenerated cache
- (BOOL)loadFromCache
{
    drawIDs.clear();
    texIDs.clear();
    
    RenderCacheReader cacheReader(cacheName);
    std::vector<Texture *> textures;
    std::vector<Drawable *> drawables;

    try
    {    
        // Try reading the cached drawables
        if (!cacheReader.getDrawablesAndTextures(textures,drawables))
            throw 1;

        // Should be as many drawables as textures
        if (texGroup.numX * texGroup.numY != drawables.size())
            throw 1;

        int whichDrawable = 0;
        for (unsigned int y = 0; y < texGroup.numY; y++)
            for (unsigned int x = 0; x < texGroup.numX; x++)
            {
                BasicDrawable *chunk = (BasicDrawable *)drawables[whichDrawable++];
                chunk->setDrawPriority(drawPriority);
                drawIDs.push_back(chunk->getId());
                
                // Now for the changes to the scenegraph
                std::vector<ChangeRequest *> changeRequests;
                
                // Ask for a new texture and wire it to the drawable
                Texture *tex = new Texture([texGroup generateFileNameX:x y:y],texGroup.ext);
                tex->setWidth(texGroup.pixelsSquare);
                tex->setHeight(texGroup.pixelsSquare);
                texIDs.push_back(tex->getId());
                changeRequests.push_back(new AddTextureReq(tex));
                chunk->setTexId(tex->getId());
                changeRequests.push_back(new AddDrawableReq(chunk));                
                scene->addChangeRequests(changeRequests);

                drawables[whichDrawable-1] = NULL;
            }
    }
    catch (...)
    {
        NSLog(@"Cache mismatch in SphericalEarthLayer.  Rebuilding.");
        
        for (unsigned int ii=0;ii<drawables.size();ii++)
            if (drawables[ii])
                delete drawables[ii];
        
        return FALSE;
    }
    
    return TRUE;
}

// First processing call.  Set things up
- (void)startProcess:(id)sender
{
    // See if there's a cache to read from first
    if (cacheName)
    {
        if (savingToCache)
        {
            // If we're saving things out, set up the cache writer
            cacheWriter = new RenderCacheWriter(cacheName);
            cacheWriter->setIgnoreTextures();
        } else {
            if ([self loadFromCache])
                return;            
        }            
    }

    // If we got here, we've got work to do.
    [self performSelector:@selector(process:) withObject:nil];
}

// Generate a list of drawables based on the sphere, but broken
//  up to match the given texture group
- (void)process:(id)sender
{
//    CoordSystem *coordSys = scene->getCoordSystem();
    
	// Unit size of each tesselation, basically
	GeoCoord geoIncr(2*M_PI/(texGroup.numX*SphereTessX),M_PI/(texGroup.numY*SphereTessY));
	
	// Texture increment for each tesselation
	TexCoord texIncr(1.0/(float)SphereTessX,1.0/(float)SphereTessY);
	
	// We're viewing this as a parameterization from ([0->1.0],[0->1.0]) so we'll
	//  break up these coordinates accordingly
	Point2f paramSize(1.0/(texGroup.numX*SphereTessX),1.0/(texGroup.numY*SphereTessY));
	// Need the four corners to set up the cullable
	GeoCoord geoLL(-M_PI + (chunkX*SphereTessX)*geoIncr.x(),-M_PI/2.0 + (chunkY*SphereTessY)*geoIncr.y());
	GeoCoord geoUR(geoLL.x()+SphereTessX*geoIncr.x(),geoLL.y()+SphereTessY*geoIncr.y());
	
	// We'll set up and fill in the drawable
	BasicDrawable *chunk = new BasicDrawable((SphereTessX+1)*(SphereTessY+1),2*SphereTessX*SphereTessY);
	chunk->setType(GL_TRIANGLES);
//	chunk->setType(GL_POINTS);
    chunk->setLocalMbr(GeoCoordSystem::GeographicMbrToLocal(GeoMbr(geoLL,geoUR)));
    chunk->setDrawPriority(drawPriority);
    
    // Texture coordinates are actually scaled down a bit to
    //  deal with borders
    TexCoord adjTexMin,adjTexMax;
    Point2f adjTexSpan;
    [texGroup calcTexMappingOrg:&adjTexMin dest:&adjTexMax];
    adjTexSpan = adjTexMax - adjTexMin;
	
	// Generate points, texture coords, and normals first
	for (unsigned int iy=0;iy<SphereTessY+1;iy++)
		for (unsigned int ix=0;ix<SphereTessX+1;ix++)
		{
			// Generate the geographic location and clamp for safety
			GeoCoord geoLoc(-M_PI + (chunkX*SphereTessX+ix)*geoIncr.x(),-M_PI/2.0 + (chunkY*SphereTessY+iy)*geoIncr.y());
			if (geoLoc.x() < -M_PI)  geoLoc.x() = -M_PI;
			if (geoLoc.x() > M_PI) geoLoc.x() = M_PI;
			if (geoLoc.y() < -M_PI/2.0)  geoLoc.y() = -M_PI/2.0;
			if (geoLoc.y() > M_PI/2.0) geoLoc.y() = M_PI/2.0;
			
			// Physical location from that
			Point3f loc = GeoCoordSystem::LocalToGeocentricish(geoLoc);
			
			// Do the texture coordinate seperately
			TexCoord texCoord((ix*texIncr.x())*adjTexSpan.x()+adjTexMin.x(),adjTexMax.y()-(iy*texIncr.y())*adjTexSpan.y());
			
			chunk->addPoint(loc);
			chunk->addTexCoord(texCoord);
			chunk->addNormal(loc);
		}
	
	// Two triangles per cell
	for (unsigned int iy=0;iy<SphereTessY;iy++)
	{
		for (unsigned int ix=0;ix<SphereTessX;ix++)
		{
			BasicDrawable::Triangle triA,triB;
			triA.verts[0] = iy*(SphereTessX+1)+ix;
			triA.verts[1] = iy*(SphereTessX+1)+(ix+1);
			triA.verts[2] = (iy+1)*(SphereTessX+1)+(ix+1);
			triB.verts[0] = triA.verts[0];
			triB.verts[1] = triA.verts[2];
			triB.verts[2] = (iy+1)*(SphereTessX+1)+ix;
			chunk->addTriangle(triA);
			chunk->addTriangle(triB);
		}
	}
	
	// Now for the changes to the scenegraph
	std::vector<ChangeRequest *> changeRequests;
	
	// Ask for a new texture and wire it to the drawable
	Texture *tex = new Texture([texGroup generateFileNameX:chunkX y:chunkY],texGroup.ext);
    tex->setWidth(texGroup.pixelsSquare);
    tex->setHeight(texGroup.pixelsSquare);
	changeRequests.push_back(new AddTextureReq(tex));
    texIDs.push_back(tex->getId());
	chunk->setTexId(tex->getId());
    if (fade > 0)
    {
        NSTimeInterval curTime = CFAbsoluteTimeGetCurrent();
        chunk->setFade(curTime,curTime+fade);
    }
	changeRequests.push_back(new AddDrawableReq(chunk));
    drawIDs.push_back(chunk->getId());
    
    // Save out to the cache if we've got one
    if (cacheWriter)
        cacheWriter->addDrawable(chunk);
	
	// This should make the changes appear
	scene->addChangeRequests(changeRequests);
	
	//	if (chunk->type == GL_POINTS)
	//		chunk->textureId = 0;

	// Move on to the next chunk
	if (++chunkX >= xDim)
	{
		chunkX = 0;
		chunkY++;
	}
	
	// Schedule the next chunk
	if (chunkY < yDim)
		[self performSelector:@selector(process:) withObject:nil afterDelay:0.0];
	else {
        if (cacheWriter)
            delete cacheWriter;
        cacheWriter = NULL;

        // If we're done, have the renderer send out a notification.
        // Odds are it's still processing the data right now
        scene->addChangeRequest(new NotificationReq(kWhirlyGlobeSphericalEarthLoaded,self));	}

}

// Calculate the size of the smallest element
- (float)smallestTesselation
{
    float smallLon = 2*M_PI/(xDim*SphereTessX);
    float smallLat = M_PI/(yDim*SphereTessY);
    
    return std::min(smallLon,smallLat);
}

// Actually make the texture group changes
- (void)runChangeTexGroup:(WhirlyKitTextureGroup *)newTexGroup
{
    texGroup = newTexGroup;
    
    // Now just run through and rebuild textures and reassign IDs
    for (unsigned int y = 0; y < texGroup.numY; y++)
        for (unsigned int x = 0; x < texGroup.numX; x++)
        {
            SimpleIdentity oldTexId = texIDs[y*texGroup.numX+x];
            
            // Set up a new texture
            Texture *tex = new Texture([texGroup generateFileNameX:x y:y],texGroup.ext);
            tex->setWidth(texGroup.pixelsSquare);
            tex->setHeight(texGroup.pixelsSquare);
            scene->addChangeRequest(new AddTextureReq(tex));
            texIDs[y*texGroup.numX+x] = tex->getId();
            
            // Reassign the drawable and delete the old texture
            SimpleIdentity drawId = drawIDs[y*texGroup.numX+x];
            scene->addChangeRequest(new DrawTexChangeRequest(drawId,tex->getId()));
            scene->addChangeRequest(new RemTextureReq(oldTexId));
        }
}

- (bool)changeTexGroup:(WhirlyKitTextureGroup *)newTexGroup
{
    // Tex group is not compatible or
    if (newTexGroup.numX != texGroup.numX ||
        newTexGroup.numY != texGroup.numY ||
        texIDs.size() != drawIDs.size() ||
        newTexGroup.numX * newTexGroup.numY != drawIDs.size())
        return false;
    
    if (!layerThread || ([NSThread currentThread] == layerThread))
        [self runChangeTexGroup:newTexGroup];
    else
        [self performSelector:@selector(runChangeTexGroup:) onThread:layerThread withObject:newTexGroup waitUntilDone:NO];
    return true;
}

@end
