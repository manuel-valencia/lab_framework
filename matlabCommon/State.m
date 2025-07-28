% File: State.m
classdef (Enumeration) State < int32
    enumeration
        BOOT (0)
        IDLE (1)
        CALIBRATING (2)
        TESTINGSENSOR (3)
        CONFIGUREVALIDATE (4)
        CONFIGUREPENDING (5)
        TESTINGACTUATOR (6)
        RUNNING (7)
        POSTPROC (8)
        DONE (9)
        ERROR (10)
    end
end