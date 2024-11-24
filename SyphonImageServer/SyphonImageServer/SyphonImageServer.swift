//
//  SyphonImageServer.swift
//  SyphonImageServer
//
//  Created by William Harris on 17.11.2024.
//

import Foundation
import CoreImage
import Metal
import AppKit
import OpenGL.GL
import IOSurface
import Syphon

class SyphonImageServer: ObservableObject {
    private var server: SyphonServer?
    private var metalDevice: MTLDevice?
    private var texture: MTLTexture?
    private var glContext: CGLContextObj?
    private var glTexture: GLuint = 0
    
    init() {
        metalDevice = MTLCreateSystemDefaultDevice()
        
        // Create OpenGL context
        var pixelFormatAttributes: [CGLPixelFormatAttribute] = [
            CGLPixelFormatAttribute(kCGLPFAAccelerated.rawValue),
            CGLPixelFormatAttribute(kCGLPFANoRecovery.rawValue),
            CGLPixelFormatAttribute(kCGLPFADoubleBuffer.rawValue),
            CGLPixelFormatAttribute(0)  // Add null terminator
        ]
        
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        let chooseResult = CGLChoosePixelFormat(&pixelFormatAttributes, &pix, &npix)
        guard chooseResult == kCGLNoError, let pixelFormat = pix else {
            print("Failed to choose pixel format: \(chooseResult)")
            return
        }
        
        defer { CGLDestroyPixelFormat(pixelFormat) }
        
        let createContextResult = CGLCreateContext(pixelFormat, nil, &glContext)
        guard createContextResult == kCGLNoError, let context = glContext else {
            print("Failed to create OpenGL context: \(createContextResult)")
            return
        }
        
        CGLSetCurrentContext(context)
        server = SyphonServer(name: "Still Image Server", context: context, options: nil)
    }
    
    func publishImage(_ nsImage: NSImage) {
        guard let metalDevice = metalDevice,
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to get CGImage from NSImage")
            return
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Create IOSurface properties
        let ioSurfaceProperties: [String: Any] = [
            String(kIOSurfaceWidth): width,
            String(kIOSurfaceHeight): height,
            String(kIOSurfaceBytesPerElement): 4,
            String(kIOSurfacePixelFormat): Int(kCVPixelFormatType_32BGRA)
        ]
        
        guard let ioSurface = IOSurfaceCreate(ioSurfaceProperties as CFDictionary) else {
            print("Failed to create IOSurface")
            return
        }
        
        // Create Metal texture from IOSurface
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let metalTexture = metalDevice.makeTexture(descriptor: textureDescriptor, iosurface: ioSurface, plane: 0) else {
            print("Failed to create Metal texture from IOSurface")
            return
        }
        
        // Render image to Metal texture
        let context = CIContext(mtlDevice: metalDevice)
        let ciImage = CIImage(cgImage: cgImage)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        
        context.render(ciImage, to: metalTexture, commandBuffer: nil, bounds: ciImage.extent, colorSpace: colorSpace)
        
        // Create OpenGL texture from IOSurface
        guard let glContext = glContext else { return }
        CGLLockContext(glContext)
        defer { CGLUnlockContext(glContext) }
        
        // Delete previous texture if it exists
        if glTexture != 0 {
            glDeleteTextures(1, &glTexture)
        }
        
        // Generate new OpenGL texture
        glGenTextures(1, &glTexture)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE_ARB), glTexture)  // Changed from GL_TEXTURE_2D

        // Set texture parameters
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE_ARB), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE_ARB), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE_ARB), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE_ARB), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)

        // Attach IOSurface to OpenGL texture with corrected format
        let result = CGLTexImageIOSurface2D(
            glContext,
            GLenum(GL_TEXTURE_RECTANGLE_ARB),  // Changed from GL_TEXTURE_2D
            GLenum(GL_RGBA8),  // Changed from GL_RGBA
            GLsizei(width),
            GLsizei(height),
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
            ioSurface,
            0
        )
        
        if result != kCGLNoError {
            print("Failed to attach IOSurface to OpenGL texture: \(result)")
            return
        }
        
        // Publish to Syphon with updated texture target
        server?.publishFrameTexture(
            glTexture,
            textureTarget: GLenum(GL_TEXTURE_RECTANGLE_ARB),  // Changed from GL_TEXTURE_2D
            imageRegion: NSRect(x: 0, y: 0, width: width, height: height),
            textureDimensions: NSSize(width: width, height: height),
            flipped: false
        )
        
        texture = metalTexture
    }
    
    deinit {
        if glTexture != 0 {
            glDeleteTextures(1, &glTexture)
        }
        
        if let context = glContext {
            CGLSetCurrentContext(nil)
            CGLDestroyContext(context)
        }
        server?.stop()
    }
}

