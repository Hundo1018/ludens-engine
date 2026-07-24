; ModuleID = 'toolchain/standin/wasm_rt.c'
source_filename = "toolchain/standin/wasm_rt.c"
target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"
target triple = "wasm32"

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: write)
define noundef ptr @memset(ptr noundef returned writeonly %0, i32 noundef %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = icmp eq i32 %2, 0
  br i1 %4, label %21, label %5

5:                                                ; preds = %3
  %6 = trunc i32 %1 to i8
  %7 = and i32 %2, 7
  %8 = icmp ult i32 %2, 8
  br i1 %8, label %11, label %9

9:                                                ; preds = %5
  %10 = and i32 %2, -8
  br label %22

11:                                               ; preds = %22, %5
  %12 = phi i32 [ 0, %5 ], [ %40, %22 ]
  %13 = icmp eq i32 %7, 0
  br i1 %13, label %21, label %14

14:                                               ; preds = %11, %14
  %15 = phi i32 [ %18, %14 ], [ %12, %11 ]
  %16 = phi i32 [ %19, %14 ], [ 0, %11 ]
  %17 = getelementptr inbounds i8, ptr %0, i32 %15
  store i8 %6, ptr %17, align 1, !tbaa !2
  %18 = add nuw i32 %15, 1
  %19 = add i32 %16, 1
  %20 = icmp eq i32 %19, %7
  br i1 %20, label %21, label %14, !llvm.loop !5

21:                                               ; preds = %11, %14, %3
  ret ptr %0

22:                                               ; preds = %22, %9
  %23 = phi i32 [ 0, %9 ], [ %40, %22 ]
  %24 = phi i32 [ 0, %9 ], [ %41, %22 ]
  %25 = getelementptr inbounds i8, ptr %0, i32 %23
  store i8 %6, ptr %25, align 1, !tbaa !2
  %26 = or disjoint i32 %23, 1
  %27 = getelementptr inbounds i8, ptr %0, i32 %26
  store i8 %6, ptr %27, align 1, !tbaa !2
  %28 = or disjoint i32 %23, 2
  %29 = getelementptr inbounds i8, ptr %0, i32 %28
  store i8 %6, ptr %29, align 1, !tbaa !2
  %30 = or disjoint i32 %23, 3
  %31 = getelementptr inbounds i8, ptr %0, i32 %30
  store i8 %6, ptr %31, align 1, !tbaa !2
  %32 = or disjoint i32 %23, 4
  %33 = getelementptr inbounds i8, ptr %0, i32 %32
  store i8 %6, ptr %33, align 1, !tbaa !2
  %34 = or disjoint i32 %23, 5
  %35 = getelementptr inbounds i8, ptr %0, i32 %34
  store i8 %6, ptr %35, align 1, !tbaa !2
  %36 = or disjoint i32 %23, 6
  %37 = getelementptr inbounds i8, ptr %0, i32 %36
  store i8 %6, ptr %37, align 1, !tbaa !2
  %38 = or disjoint i32 %23, 7
  %39 = getelementptr inbounds i8, ptr %0, i32 %38
  store i8 %6, ptr %39, align 1, !tbaa !2
  %40 = add nuw i32 %23, 8
  %41 = add i32 %24, 8
  %42 = icmp eq i32 %41, %10
  br i1 %42, label %11, label %22, !llvm.loop !7
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite)
define noundef ptr @memcpy(ptr noundef returned writeonly %0, ptr nocapture noundef readonly %1, i32 noundef %2) local_unnamed_addr #1 {
  %4 = icmp eq i32 %2, 0
  br i1 %4, label %22, label %5

5:                                                ; preds = %3
  %6 = and i32 %2, 3
  %7 = icmp ult i32 %2, 4
  br i1 %7, label %10, label %8

8:                                                ; preds = %5
  %9 = and i32 %2, -4
  br label %23

10:                                               ; preds = %23, %5
  %11 = phi i32 [ 0, %5 ], [ %41, %23 ]
  %12 = icmp eq i32 %6, 0
  br i1 %12, label %22, label %13

13:                                               ; preds = %10, %13
  %14 = phi i32 [ %19, %13 ], [ %11, %10 ]
  %15 = phi i32 [ %20, %13 ], [ 0, %10 ]
  %16 = getelementptr inbounds i8, ptr %1, i32 %14
  %17 = load i8, ptr %16, align 1, !tbaa !2
  %18 = getelementptr inbounds i8, ptr %0, i32 %14
  store i8 %17, ptr %18, align 1, !tbaa !2
  %19 = add nuw i32 %14, 1
  %20 = add i32 %15, 1
  %21 = icmp eq i32 %20, %6
  br i1 %21, label %22, label %13, !llvm.loop !9

22:                                               ; preds = %10, %13, %3
  ret ptr %0

23:                                               ; preds = %23, %8
  %24 = phi i32 [ 0, %8 ], [ %41, %23 ]
  %25 = phi i32 [ 0, %8 ], [ %42, %23 ]
  %26 = getelementptr inbounds i8, ptr %1, i32 %24
  %27 = load i8, ptr %26, align 1, !tbaa !2
  %28 = getelementptr inbounds i8, ptr %0, i32 %24
  store i8 %27, ptr %28, align 1, !tbaa !2
  %29 = or disjoint i32 %24, 1
  %30 = getelementptr inbounds i8, ptr %1, i32 %29
  %31 = load i8, ptr %30, align 1, !tbaa !2
  %32 = getelementptr inbounds i8, ptr %0, i32 %29
  store i8 %31, ptr %32, align 1, !tbaa !2
  %33 = or disjoint i32 %24, 2
  %34 = getelementptr inbounds i8, ptr %1, i32 %33
  %35 = load i8, ptr %34, align 1, !tbaa !2
  %36 = getelementptr inbounds i8, ptr %0, i32 %33
  store i8 %35, ptr %36, align 1, !tbaa !2
  %37 = or disjoint i32 %24, 3
  %38 = getelementptr inbounds i8, ptr %1, i32 %37
  %39 = load i8, ptr %38, align 1, !tbaa !2
  %40 = getelementptr inbounds i8, ptr %0, i32 %37
  store i8 %39, ptr %40, align 1, !tbaa !2
  %41 = add nuw i32 %24, 4
  %42 = add i32 %25, 4
  %43 = icmp eq i32 %42, %9
  br i1 %43, label %10, label %23, !llvm.loop !10
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite)
define noundef ptr @memmove(ptr noundef returned writeonly %0, ptr noundef readonly %1, i32 noundef %2) local_unnamed_addr #1 {
  %4 = icmp ult ptr %0, %1
  %5 = icmp eq i32 %2, 0
  br i1 %4, label %22, label %6

6:                                                ; preds = %3
  br i1 %5, label %80, label %7

7:                                                ; preds = %6
  %8 = and i32 %2, 3
  %9 = icmp eq i32 %8, 0
  br i1 %9, label %19, label %10

10:                                               ; preds = %7, %10
  %11 = phi i32 [ %13, %10 ], [ %2, %7 ]
  %12 = phi i32 [ %17, %10 ], [ 0, %7 ]
  %13 = add i32 %11, -1
  %14 = getelementptr inbounds i8, ptr %1, i32 %13
  %15 = load i8, ptr %14, align 1, !tbaa !2
  %16 = getelementptr inbounds i8, ptr %0, i32 %13
  store i8 %15, ptr %16, align 1, !tbaa !2
  %17 = add i32 %12, 1
  %18 = icmp eq i32 %17, %8
  br i1 %18, label %19, label %10, !llvm.loop !11

19:                                               ; preds = %10, %7
  %20 = phi i32 [ %2, %7 ], [ %13, %10 ]
  %21 = icmp ult i32 %2, 4
  br i1 %21, label %80, label %49

22:                                               ; preds = %3
  br i1 %5, label %80, label %23

23:                                               ; preds = %22
  %24 = and i32 %2, 3
  %25 = icmp ult i32 %2, 4
  br i1 %25, label %68, label %26

26:                                               ; preds = %23
  %27 = and i32 %2, -4
  br label %28

28:                                               ; preds = %28, %26
  %29 = phi i32 [ 0, %26 ], [ %46, %28 ]
  %30 = phi i32 [ 0, %26 ], [ %47, %28 ]
  %31 = getelementptr inbounds i8, ptr %1, i32 %29
  %32 = load i8, ptr %31, align 1, !tbaa !2
  %33 = getelementptr inbounds i8, ptr %0, i32 %29
  store i8 %32, ptr %33, align 1, !tbaa !2
  %34 = or disjoint i32 %29, 1
  %35 = getelementptr inbounds i8, ptr %1, i32 %34
  %36 = load i8, ptr %35, align 1, !tbaa !2
  %37 = getelementptr inbounds i8, ptr %0, i32 %34
  store i8 %36, ptr %37, align 1, !tbaa !2
  %38 = or disjoint i32 %29, 2
  %39 = getelementptr inbounds i8, ptr %1, i32 %38
  %40 = load i8, ptr %39, align 1, !tbaa !2
  %41 = getelementptr inbounds i8, ptr %0, i32 %38
  store i8 %40, ptr %41, align 1, !tbaa !2
  %42 = or disjoint i32 %29, 3
  %43 = getelementptr inbounds i8, ptr %1, i32 %42
  %44 = load i8, ptr %43, align 1, !tbaa !2
  %45 = getelementptr inbounds i8, ptr %0, i32 %42
  store i8 %44, ptr %45, align 1, !tbaa !2
  %46 = add nuw i32 %29, 4
  %47 = add i32 %30, 4
  %48 = icmp eq i32 %47, %27
  br i1 %48, label %68, label %28, !llvm.loop !12

49:                                               ; preds = %19, %49
  %50 = phi i32 [ %63, %49 ], [ %20, %19 ]
  %51 = add i32 %50, -1
  %52 = getelementptr inbounds i8, ptr %1, i32 %51
  %53 = load i8, ptr %52, align 1, !tbaa !2
  %54 = getelementptr inbounds i8, ptr %0, i32 %51
  store i8 %53, ptr %54, align 1, !tbaa !2
  %55 = add i32 %50, -2
  %56 = getelementptr inbounds i8, ptr %1, i32 %55
  %57 = load i8, ptr %56, align 1, !tbaa !2
  %58 = getelementptr inbounds i8, ptr %0, i32 %55
  store i8 %57, ptr %58, align 1, !tbaa !2
  %59 = add i32 %50, -3
  %60 = getelementptr inbounds i8, ptr %1, i32 %59
  %61 = load i8, ptr %60, align 1, !tbaa !2
  %62 = getelementptr inbounds i8, ptr %0, i32 %59
  store i8 %61, ptr %62, align 1, !tbaa !2
  %63 = add i32 %50, -4
  %64 = getelementptr inbounds i8, ptr %1, i32 %63
  %65 = load i8, ptr %64, align 1, !tbaa !2
  %66 = getelementptr inbounds i8, ptr %0, i32 %63
  store i8 %65, ptr %66, align 1, !tbaa !2
  %67 = icmp eq i32 %63, 0
  br i1 %67, label %80, label %49, !llvm.loop !13

68:                                               ; preds = %28, %23
  %69 = phi i32 [ 0, %23 ], [ %46, %28 ]
  %70 = icmp eq i32 %24, 0
  br i1 %70, label %80, label %71

71:                                               ; preds = %68, %71
  %72 = phi i32 [ %77, %71 ], [ %69, %68 ]
  %73 = phi i32 [ %78, %71 ], [ 0, %68 ]
  %74 = getelementptr inbounds i8, ptr %1, i32 %72
  %75 = load i8, ptr %74, align 1, !tbaa !2
  %76 = getelementptr inbounds i8, ptr %0, i32 %72
  store i8 %75, ptr %76, align 1, !tbaa !2
  %77 = add nuw i32 %72, 1
  %78 = add i32 %73, 1
  %79 = icmp eq i32 %78, %24
  br i1 %79, label %80, label %71, !llvm.loop !14

80:                                               ; preds = %19, %49, %68, %71, %6, %22
  ret ptr %0
}

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: write) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" }
attributes #1 = { nofree norecurse nosync nounwind memory(argmem: readwrite) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!"Ubuntu clang version 18.1.3 (1ubuntu1)"}
!2 = !{!3, !3, i64 0}
!3 = !{!"omnipotent char", !4, i64 0}
!4 = !{!"Simple C/C++ TBAA"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.unroll.disable"}
!7 = distinct !{!7, !8}
!8 = !{!"llvm.loop.mustprogress"}
!9 = distinct !{!9, !6}
!10 = distinct !{!10, !8}
!11 = distinct !{!11, !6}
!12 = distinct !{!12, !8}
!13 = distinct !{!13, !8}
!14 = distinct !{!14, !6}
